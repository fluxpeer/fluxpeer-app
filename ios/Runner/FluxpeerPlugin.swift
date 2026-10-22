// SPDX-License-Identifier: AGPL-3.0-or-later
import Flutter
import NetworkExtension
import UIKit
import UserNotifications

/// iOS counterpart of Android's `MainActivity` channel handlers + the
/// `NETunnelProviderManager` driver. Bridges the Flutter channels to the tunnel:
///   - MethodChannel `dev.fluxpeer.app/flux`      — join / start / stop / getCurrentState
///   - EventChannel  `dev.fluxpeer.app/fluxStatus` — live snapshots (NEVPNStatus)
///
/// `join` (keygen + enroll) runs in this app process and persists a connect
/// record into the shared App Group; `start` merges local policy, hands the
/// record to the PacketTunnelProvider via `providerConfiguration`, and starts it.
final class FluxpeerPlugin: NSObject, FlutterStreamHandler {

    static let extensionBundleId = "dev.fluxpeer.fluxpeer.PacketTunnel"
    static let appGroup = "group.dev.fluxpeer.fluxpeer"

    private var operationPending = false
    private var manager: NETunnelProviderManager?
    private var sink: FlutterEventSink?
    private var snapshot: [String: Any] = ["state": "disconnected", "peers": []]

    private var store: UserDefaults { UserDefaults(suiteName: Self.appGroup) ?? .standard }

    static func register(with registrar: FlutterPluginRegistrar) {
        let inst = FluxpeerPlugin()
        let m = FlutterMethodChannel(name: "dev.fluxpeer.app/flux", binaryMessenger: registrar.messenger())
        m.setMethodCallHandler { inst.handle($0, $1) }
        FlutterEventChannel(name: "dev.fluxpeer.app/fluxStatus", binaryMessenger: registrar.messenger())
            .setStreamHandler(inst)
        inst.loadManager()
        NotificationCenter.default.addObserver(inst, selector: #selector(inst.statusChanged),
                                               name: .NEVPNStatusDidChange, object: nil)
    }

    // MARK: - MethodChannel

    private func handle(_ call: FlutterMethodCall, _ result: @escaping FlutterResult) {
        let mutating = ["join", "start", "leave", "stop"].contains(call.method)
        if mutating && operationPending { result(FlutterError(code: "busy", message: "Native operation pending", details: nil)); return }
        if mutating { operationPending = true }
        let complete: FlutterResult = { value in
            DispatchQueue.main.async {
                if mutating { self.operationPending = false }
                result(value)
            }
        }
        handleOperation(call, complete)
    }

    private func handleOperation(_ call: FlutterMethodCall, _ result: @escaping FlutterResult) {
        switch call.method {
        case "leave": leave(call.arguments as? [String: Any] ?? [:], result)
        case "join": join(call.arguments as? [String: Any] ?? [:], result)
        case "start": start(call.arguments as? [String: Any] ?? [:], result)
        case "stop": manager?.connection.stopVPNTunnel(); result(nil)
        case "getCurrentState": result(snapshot)
        // Me-tab system settings / permissions. iOS keepalive is handled by the
        // NE framework, so there is no battery/autostart knob — those are null
        // (the UI hides them). VPN = the profile is installed; notifications =
        // UNUserNotificationCenter authorization.
        case "permissionStatus": permissionStatus(result)
        case "requestVpn": requestVpnProfile(result)
        case "requestNotifications": requestNotifications(result)
        case "openAutoStart": openAppSettings(); result(nil)
        case "requestBatteryExemption": openAppSettings(); result(nil)
        default: result(FlutterMethodNotImplemented)
        }
    }

    /// keygen → enroll → persist connect record → return the Dart FxNetwork.
    private func join(_ args: [String: Any], _ result: @escaping FlutterResult) {
        let token = args["token"] as? String ?? ""
        let device = (args["device"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "ios"
        DispatchQueue.global().async {
            do {
                let kp = try FluxpeerNative.unwrap(FluxpeerNative.generateKeypair()) as? [String: Any] ?? [:]
                let pub = kp["public_key"] as? String ?? ""
                let priv = kp["private_key"] as? String ?? ""
                // enroll needs the PRIVATE key for proof-of-possession (audit #11);
                // the SDK derives the public half + ECDH proof natively.
                let enrollReq = self.json(["token": token, "name": device, "wg_private_key": priv, "wg_public_key": pub])
                let dev = try FluxpeerNative.unwrap(FluxpeerNative.enroll(enrollReq)) as? [String: Any] ?? [:]

                let networkId = (dev["network_id"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                    ?? (dev["id"] as? String ?? "")
                let record: [String: Any] = [
                    "networkId": networkId,
                    "name": device,
                    "controlUrl": dev["control_server"] as? String ?? "",
                    "overlayV4": dev["address_v4"] as? String ?? "",
                    "deviceId": dev["id"] as? String ?? "",
                    "auth_token": dev["auth_token"] as? String ?? "",
                    "pubkey": pub,
                    "client_prikey": priv,
                    "transport_protocol": "udp",
                    "crypto_protocol": "noise",
                    "mtu": 1380,
                ]
                try self.saveRecord(networkId, record)
                DispatchQueue.main.async { result(self.toDart(record)) }
            } catch {
                DispatchQueue.main.async { result(FlutterError(code: "join_failed", message: "\(error)", details: nil)) }
            }
        }
    }

    /// Pass complete local policy; the engine fetches fresh membership on every start.
    private func start(_ args: [String: Any], _ result: @escaping FlutterResult) {
        let net: [String: Any]
        var record: [String: Any]
        let networkId: String
        do {
            net = try networkArgument(args)
            guard net["needsRejoin"] as? Bool != true else { throw MembershipStore.failure("Rejoin this network before connecting") }
            networkId = try MembershipStore.key(net)
            guard let saved = try loadRecord(networkId) else { throw MembershipStore.failure("Rejoin this network before connecting") }
            record = saved
        } catch { result(FlutterError(code: "start_failed", message: "\(error)", details: nil)); return }

        do {
            record = try TunnelPolicy.merge(record, net)
            try saveRecord(networkId, record)
            installAndStart(record, result)
        } catch { result(FlutterError(code: "start_failed", message: "\(error)", details: nil)) }
    }

    private func networkArgument(_ args: [String: Any]) throws -> [String: Any] {
        guard let raw = args["network"] as? String, let data = raw.data(using: .utf8),
              let net = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { throw MembershipStore.failure("Missing network identity") }
        return net
    }

    /// Keep UI membership until the matching extension has stopped and its saved
    /// profile (including credentials in providerConfiguration) has been removed.
    private func leave(_ args: [String: Any], _ result: @escaping FlutterResult) {
        let key: String
        do { key = try MembershipStore.key(networkArgument(args)); try MembershipStore(defaults: store).migrate() }
        catch { result(FlutterError(code: "leave_failed", message: "\(error)", details: nil)); return }
        NETunnelProviderManager.loadAllFromPreferences { managers, error in
            if let error { result(FlutterError(code: "leave_failed", message: "\(error)", details: nil)); return }
            DispatchQueue.main.async {
                do {
                    let matching = try (managers ?? []).filter { manager in
                        guard let proto = manager.protocolConfiguration as? NETunnelProviderProtocol,
                              proto.providerBundleIdentifier == Self.extensionBundleId,
                              let raw = proto.providerConfiguration?["flux_config"] as? String else { return false }
                        return try MembershipStore.key(self.networkArgument(["network": raw])) == key
                    }
                    self.removeProfiles(matching, key: key, result: result)
                } catch { result(FlutterError(code: "leave_failed", message: "\(error)", details: nil)) }
            }
        }
    }

    private func removeProfiles(_ profiles: [NETunnelProviderManager], key: String, result: @escaping FlutterResult) {
        guard let profile = profiles.first else {
            do { try MembershipStore(defaults: store).remove(key); result(nil) }
            catch { result(FlutterError(code: "leave_failed", message: "\(error)", details: nil)) }
            return
        }
        profile.isOnDemandEnabled = false
        profile.saveToPreferences { error in
            if let error { result(FlutterError(code: "leave_failed", message: "\(error)", details: nil)); return }
            DispatchQueue.main.async {
                profile.connection.stopVPNTunnel()
                self.waitForStop(profile, deadline: Date().addingTimeInterval(10)) { error in
                    if let error { result(FlutterError(code: "leave_failed", message: "\(error)", details: nil)); return }
                    profile.removeFromPreferences { error in
                        DispatchQueue.main.async {
                            if let error { result(FlutterError(code: "leave_failed", message: "\(error)", details: nil)); return }
                            if self.managerKey() == key || self.snapshot["networkId"] as? String == key {
                                self.manager = nil
                                self.snapshot = ["state": "disconnected", "peers": []]
                                self.sink?(self.snapshot)
                            }
                            self.removeProfiles(Array(profiles.dropFirst()), key: key, result: result)
                        }
                    }
                }
            }
        }
    }

    private func waitForStop(_ profile: NETunnelProviderManager, deadline: Date, complete: @escaping (Error?) -> Void) {
        if [.disconnected, .invalid].contains(profile.connection.status) { complete(nil); return }
        if Date() >= deadline { complete(MembershipStore.failure("Tunnel stop timed out; membership retained")); return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { self.waitForStop(profile, deadline: deadline, complete: complete) }
    }

    private func installAndStart(_ record: [String: Any], _ result: @escaping FlutterResult) {
        let mgr = manager ?? NETunnelProviderManager()
        let proto = NETunnelProviderProtocol()
        proto.providerBundleIdentifier = Self.extensionBundleId
        proto.serverAddress = record["controlUrl"] as? String ?? "fluxpeer"
        proto.providerConfiguration = ["flux_config": json(record)]
        mgr.protocolConfiguration = proto
        mgr.localizedDescription = "fluxpeer"
        mgr.isEnabled = true
        mgr.saveToPreferences { [weak self] error in
            if let error { return result(FlutterError(code: "save_failed", message: "\(error)", details: nil)) }
            // Reload (saveToPreferences invalidates the in-memory object) then start.
            mgr.loadFromPreferences { error in
                if let error { result(FlutterError(code: "load_failed", message: "\(error)", details: nil)); return }
                self?.manager = mgr
                do { try mgr.connection.startVPNTunnel(); result(nil) }
                catch { result(FlutterError(code: "start_failed", message: "\(error)", details: nil)) }
            }
        }
    }

    // MARK: - permissions (Me-tab system settings)

    private func permissionStatus(_ result: @escaping FlutterResult) {
        let vpn = (manager != nil) // VPN profile installed
        UNUserNotificationCenter.current().getNotificationSettings { s in
            let notif = (s.authorizationStatus == .authorized || s.authorizationStatus == .provisional)
            DispatchQueue.main.async {
                // battery/autostart are Android-only → null (UI hides them).
                result(["vpn": vpn, "notifications": notif, "battery": NSNull(), "autostart": NSNull()])
            }
        }
    }

    /// On iOS the VPN-config consent is prompted on the first `start`
    /// (saveToPreferences). From settings we just deep-link to the app settings.
    private func requestVpnProfile(_ result: @escaping FlutterResult) {
        openAppSettings()
        result(nil)
    }

    private func requestNotifications(_ result: @escaping FlutterResult) {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
            DispatchQueue.main.async { result(granted) }
        }
    }

    private func openAppSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) {
            DispatchQueue.main.async { UIApplication.shared.open(url) }
        }
    }

    // MARK: - manager + status

    private func loadManager() {
        NETunnelProviderManager.loadAllFromPreferences { [weak self] managers, _ in
            self?.manager = managers?.first { ($0.protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier == Self.extensionBundleId }
            self?.statusChanged()
        }
    }

    private func managerKey() -> String? {
        guard let proto = manager?.protocolConfiguration as? NETunnelProviderProtocol,
              let raw = proto.providerConfiguration?["flux_config"] as? String,
              let record = try? networkArgument(["network": raw]) else { return nil }
        return try? MembershipStore.key(record)
    }

    @objc private func statusChanged() {
        let state: String
        switch manager?.connection.status ?? .disconnected {
        case .connecting, .reasserting: state = "connecting"
        case .connected: state = "connected"
        case .disconnecting: state = "disconnecting"
        default: state = "disconnected"
        }
        var snap: [String: Any] = ["state": state, "peers": []]
        if let proto = manager?.protocolConfiguration as? NETunnelProviderProtocol,
           let raw = proto.providerConfiguration?["flux_config"] as? String,
           let record = try? networkArgument(["network": raw]), let key = try? MembershipStore.key(record) { snap["networkId"] = key }
        if state == "connected" { snap["connectedAtMs"] = Int(Date().timeIntervalSince1970 * 1000) }
        snapshot = snap
        DispatchQueue.main.async { self.sink?(snap) }
    }

    // MARK: - FlutterStreamHandler

    func onListen(withArguments _: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        sink = events; events(snapshot); return nil
    }
    func onCancel(withArguments _: Any?) -> FlutterError? { sink = nil; return nil }

    // MARK: - persistence + helpers

    private func saveRecord(_ id: String, _ record: [String: Any]) throws {
        try MembershipStore(defaults: store).save(record)
    }
    private func loadRecord(_ id: String) throws -> [String: Any]? {
        try MembershipStore(defaults: store).load(id)
    }

    private func json(_ obj: [String: Any]) -> String {
        guard let d = try? JSONSerialization.data(withJSONObject: obj) else { return "{}" }
        return String(data: d, encoding: .utf8) ?? "{}"
    }

    private func toDart(_ r: [String: Any]) -> [String: Any] {
        [
            "id": r["networkId"] ?? "",
            "name": r["name"] ?? "network",
            "controlUrl": r["controlUrl"] ?? "",
            "overlayV4": (r["overlayV4"] as? String).flatMap { $0.isEmpty ? nil : $0 } as Any,
            "deviceId": r["deviceId"] as Any,
            "pubkey": r["pubkey"] as Any,
            "mtu": r["mtu"] ?? 1380,
            "dns": r["dns"] ?? [],
            "exitNode": r["exitNode"] ?? false,
            "excludeRoutes": r["excludeRoutes"] ?? [],
        ]
    }
}
