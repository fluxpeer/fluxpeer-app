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
/// record into the shared App Group; `start` resolves the gateway, hands the
/// record to the PacketTunnelProvider via `providerConfiguration`, and starts it.
final class FluxpeerPlugin: NSObject, FlutterStreamHandler {

    static let extensionBundleId = "dev.fluxpeer.fluxpeer.PacketTunnel"
    static let appGroup = "group.dev.fluxpeer.fluxpeer"

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
        switch call.method {
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
                var record: [String: Any] = [
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
                self.saveRecord(networkId, record)
                DispatchQueue.main.async { result(self.toDart(record)) }
            } catch {
                DispatchQueue.main.async { result(FlutterError(code: "join_failed", message: "\(error)", details: nil)) }
            }
        }
    }

    /// Resolve the gateway, fold node_* into the record, then save + start the tunnel.
    private func start(_ args: [String: Any], _ result: @escaping FlutterResult) {
        guard let netJson = args["network"] as? String,
              let netData = netJson.data(using: .utf8),
              let net = (try? JSONSerialization.jsonObject(with: netData)) as? [String: Any],
              let networkId = net["id"] as? String, !networkId.isEmpty,
              var record = loadRecord(networkId)
        else { return result(FlutterError(code: "bad_args", message: "unknown network", details: nil)) }

        let userTransport = (net["user_transport"] as? String) ?? ""

        DispatchQueue.global().async {
            if (record["node_addr"] as? String ?? "").isEmpty {
                self.resolveGateway(&record)
            }
            // A user-chosen mode wins over the gateway-advertised default; the
            // extension hands the record straight to the FFI, which reads
            // `transport_protocol`. Empty userTransport = 'auto' → keep default.
            if !userTransport.isEmpty { record["transport_protocol"] = userTransport }
            self.saveRecord(networkId, record)
            guard !(record["node_addr"] as? String ?? "").isEmpty else {
                DispatchQueue.main.async { result(FlutterError(code: "no_gateway", message: "no reachable gateway yet", details: nil)) }
                return
            }
            DispatchQueue.main.async { self.installAndStart(record, result) }
        }
    }

    private func resolveGateway(_ record: inout [String: Any]) {
        let ctrl = record["controlUrl"] as? String ?? ""
        let deviceId = record["deviceId"] as? String ?? ""
        let authToken = record["auth_token"] as? String ?? ""
        guard !ctrl.isEmpty, !deviceId.isEmpty else { return }
        let req = json(["ctrl": ctrl, "device_id": deviceId, "auth_token": authToken])
        guard let gw = try? FluxpeerNative.unwrap(FluxpeerNative.gateway(req)) as? [String: Any] else { return }
        record["node_pubkey"] = gw["node_pubkey"]
        record["node_addr"] = gw["node_addr"]
        record["node_port"] = gw["node_port"]
        if let t = gw["transport_protocol"] as? String, !t.isEmpty { record["transport_protocol"] = t }
        if let r = gw["allowed_routes"] { record["allowed_routes"] = r }
        if let d = gw["dns"] as? [String], !d.isEmpty { record["dns"] = d }
        if let m = gw["mtu"] { record["mtu"] = m }
    }

    private func installAndStart(_ record: [String: Any], _ result: @escaping FlutterResult) {
        let mgr = manager ?? NETunnelProviderManager()
        let proto = NETunnelProviderProtocol()
        proto.providerBundleIdentifier = Self.extensionBundleId
        proto.serverAddress = record["node_addr"] as? String ?? "fluxpeer"
        proto.providerConfiguration = ["flux_config": json(record)]
        mgr.protocolConfiguration = proto
        mgr.localizedDescription = "fluxpeer"
        mgr.isEnabled = true
        mgr.saveToPreferences { [weak self] error in
            if let error { return result(FlutterError(code: "save_failed", message: "\(error)", details: nil)) }
            // Reload (saveToPreferences invalidates the in-memory object) then start.
            mgr.loadFromPreferences { _ in
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
            self?.manager = managers?.first
            self?.statusChanged()
        }
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

    private func saveRecord(_ id: String, _ record: [String: Any]) {
        store.set(json(record), forKey: "network.\(id)")
    }
    private func loadRecord(_ id: String) -> [String: Any]? {
        guard let s = store.string(forKey: "network.\(id)"), let d = s.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: d)) as? [String: Any]
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
