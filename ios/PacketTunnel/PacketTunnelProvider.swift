// SPDX-License-Identifier: AGPL-3.0-or-later
import NetworkExtension

final class PacketTunnelProvider: NEPacketTunnelProvider {
    private let engineQueue = DispatchQueue(label: "fluxpeer.engine.lifecycle")
    private var lifecycle = TunnelLifecycle()
    private var bridge: PacketBridge?
    private var record: [String: Any] = [:]
    private var starting: ((Error?) -> Void)?
    private var stopping = false
    private var routeInFlight = false
    private var engineStopped = false
    private var stopError: Error?
    private var stopWaiters: [(Error?) -> Void] = []

    override func startTunnel(options: [String: NSObject]?, completionHandler: @escaping (Error?) -> Void) {
        DispatchQueue.main.async { self.start(completionHandler) }
    }
    private func start(_ completion: @escaping (Error?) -> Void) {
        guard !lifecycle.active && !stopping && !routeInFlight else { completion(TunnelPolicy.error("Tunnel lifecycle busy")); return }
        do {
            guard let proto = protocolConfiguration as? NETunnelProviderProtocol,
                  let json = proto.providerConfiguration?["flux_config"] as? String,
                  let data = json.data(using: .utf8), let record = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { throw TunnelPolicy.error("Invalid tunnel configuration") }
            let config = String(decoding: try JSONSerialization.data(withJSONObject: TunnelPolicy.engine(record)), as: UTF8.self)
            self.record = record; let generation = lifecycle.begin(); starting = completion
            let bridge = try PacketBridge(packetFlow); self.bridge = bridge
            bridge.failed = { [weak self] error in self?.fail(error, generation) }
            FluxpeerNative.observe { [weak self] generation, kind, json in
                guard let self else { return -1 }
                if kind == 1 { return self.applyRoutes(json, generation) }
                DispatchQueue.main.async {
                    guard self.lifecycle.accepts(generation) else { return }
                    if kind == 2 && self.lifecycle.ready(generation) {
                        let complete = self.starting; self.starting = nil; complete?(nil)
                    } else if kind == 3 { self.fail(TunnelPolicy.error(json), generation) }
                }
                return 0
            }
            try bridge.startEngine(config, generation: generation)
        } catch {
            if lifecycle.active { fail(error, lifecycle.generation) } else { completion(error) }
        }
    }
    private func applyRoutes(_ json: String, _ generation: UInt64) -> Int32 {
        let complete = DispatchSemaphore(value: 0)
        let result = RouteResult()
        DispatchQueue.main.async {
            guard self.lifecycle.accepts(generation) else { complete.signal(); return }
            do {
                guard let data = json.data(using: .utf8), let applied = try JSONSerialization.jsonObject(with: data) as? [String: Any]
                else { throw TunnelPolicy.error("Invalid engine routes") }
                let plan = try TunnelPolicy.plan(self.record, applied)
                let settings = self.settings(plan)
                self.routeInFlight = true
                self.setTunnelNetworkSettings(settings) { error in
                    DispatchQueue.main.async {
                        self.routeInFlight = false
                        guard self.lifecycle.accepts(generation) else { complete.signal(); self.finishStop(); return }
                        if let error { self.fail(error, generation) }
                        else {
                            self.bridge?.blockIPv6 = plan.full
                            self.bridge?.startPackets()
                            self.lifecycle.routesApplied(generation); result.succeed()
                        }
                        complete.signal()
                    }
                }
            } catch { self.fail(error, generation); complete.signal() }
        }
        if complete.wait(timeout: .now() + 10) != .success {
            DispatchQueue.main.async { self.fail(TunnelPolicy.error("Route application timed out"), generation) }
            return -1
        }
        return result.value()
    }
    private func fail(_ error: Error, _ generation: UInt64) {
        guard lifecycle.accepts(generation) else { return }
        teardown { stopError in
            let complete = self.starting; self.starting = nil
            complete?(stopError ?? error)
            self.cancelTunnelWithError(stopError ?? error)
        }
    }
    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        DispatchQueue.main.async {
            self.teardown { error in
                let complete = self.starting; self.starting = nil
                complete?(error ?? TunnelPolicy.error("Tunnel stopped before ready"))
                if let error { self.cancelTunnelWithError(error) }
                completionHandler()
            }
        }
    }
    private func teardown(_ complete: @escaping (Error?) -> Void) {
        stopWaiters.append(complete)
        if stopping { return }
        let generation = lifecycle.stop(); stopping = true; engineStopped = false; stopError = nil
        bridge?.close(); bridge = nil
        FluxpeerNative.observe(nil)
        // Never join from the callback/main thread: route application waits for NE.
        engineQueue.async {
            var error: Error?
            do { _ = try FluxpeerNative.unwrap(FluxpeerNative.stop(generation)) } catch let failure { error = failure }
            DispatchQueue.main.async { self.engineStopped = true; self.stopError = error; self.finishStop() }
        }
    }
    private func finishStop() {
        guard stopping && engineStopped && !routeInFlight else { return }
        stopping = false
        let waiters = stopWaiters; stopWaiters.removeAll()
        for complete in waiters { complete(stopError) }
    }
    private func settings(_ plan: TunnelPlan) -> NEPacketTunnelNetworkSettings {
        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: plan.v4)
        settings.mtu = NSNumber(value: plan.mtu)
        let v4 = NEIPv4Settings(addresses: [plan.v4], subnetMasks: ["255.255.255.255"])
        v4.includedRoutes = plan.routes.filter { !$0.v6 }.map { NEIPv4Route(destinationAddress: $0.address, subnetMask: $0.mask) }
        v4.excludedRoutes = plan.excludes.filter { !$0.v6 }.map { NEIPv4Route(destinationAddress: $0.address, subnetMask: $0.mask) }
        settings.ipv4Settings = v4
        if let address = plan.v6 {
            let v6 = NEIPv6Settings(addresses: [address], networkPrefixLengths: [128])
            v6.includedRoutes = plan.routes.filter { $0.v6 }.map { NEIPv6Route(destinationAddress: $0.address, networkPrefixLength: NSNumber(value: $0.length)) }
            v6.excludedRoutes = plan.excludes.filter { $0.v6 }.map { NEIPv6Route(destinationAddress: $0.address, networkPrefixLength: NSNumber(value: $0.length)) }
            settings.ipv6Settings = v6
        }
        if !plan.dns.isEmpty { let dns = NEDNSSettings(servers: plan.dns); dns.matchDomains = [""]; settings.dnsSettings = dns }
        return settings
    }
}
private final class RouteResult {
    private let lock = NSLock(); private var status: Int32 = -1
    func succeed() { lock.lock(); status = 0; lock.unlock() }
    func value() -> Int32 { lock.lock(); defer { lock.unlock() }; return status }
}
