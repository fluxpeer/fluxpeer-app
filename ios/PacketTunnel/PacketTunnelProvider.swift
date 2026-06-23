// SPDX-License-Identifier: AGPL-3.0-or-later
import NetworkExtension

/// Runs the fluxpeer node in-process inside the Network Extension and bridges
/// the OS utun to the engine. iOS counterpart of Android's `FluxpeerVpnService`.
///
/// Two-phase (matching the FFI contract):
///   1. `connectHandshakeOnly` — transport + Noise handshake (NO tun yet).
///   2. `setTunnelNetworkSettings` (split-tunnel routes), then adopt the utun fd
///      and `attachTun` it → data plane live.
///
/// The connect record (with the gateway `node_*` already resolved by the app)
/// arrives in `providerConfiguration["flux_config"]`.
class PacketTunnelProvider: NEPacketTunnelProvider {

    private static let fallbackDNS = ["1.1.1.1", "8.8.8.8"]

    override func startTunnel(options: [String: NSObject]?, completionHandler: @escaping (Error?) -> Void) {
        guard let proto = protocolConfiguration as? NETunnelProviderProtocol,
              let cfgString = proto.providerConfiguration?["flux_config"] as? String,
              let cfgData = cfgString.data(using: .utf8),
              let cfg = (try? JSONSerialization.jsonObject(with: cfgData)) as? [String: Any]
        else { return completionHandler(err(-1, "invalid tunnel configuration")) }

        guard let nodeAddr = cfg["node_addr"] as? String, !nodeAddr.isEmpty,
              let overlayV4 = (cfg["iface_ipv4"] ?? cfg["overlayV4"]) as? String, !overlayV4.isEmpty
        else { return completionHandler(err(-2, "missing node_addr / overlay address")) }

        // Engine `ClientStartReq` field names match the connect record, so the
        // stored JSON is forwarded verbatim as the handshake request.
        let resp = FluxpeerNative.connectHandshakeOnly(cfgString)
        do { _ = try FluxpeerNative.unwrap(resp) } catch {
            return completionHandler(err(-3, "handshake failed: \(error)"))
        }

        let settings = makeSettings(remote: nodeAddr, overlayV4: overlayV4, cfg: cfg)
        setTunnelNetworkSettings(settings) { [weak self] error in
            guard let self else { return }
            if let error { return completionHandler(error) }

            let fd = self.utunFileDescriptor()
            guard fd > 0 else { return completionHandler(self.err(-4, "could not obtain utun fd")) }
            let attach = FluxpeerNative.attachTun(fd)
            do { _ = try FluxpeerNative.unwrap(attach) } catch {
                return completionHandler(self.err(-5, "attach_tun failed: \(error)"))
            }
            completionHandler(nil)
        }
    }

    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        _ = FluxpeerNative.disconnect()
        completionHandler()
    }

    // MARK: - tunnel settings (split-tunnel by default)

    private func makeSettings(remote: String, overlayV4: String, cfg: [String: Any]) -> NEPacketTunnelNetworkSettings {
        let s = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: remote)
        s.mtu = NSNumber(value: (cfg["mtu"] as? Int) ?? 1380)

        let v4 = NEIPv4Settings(addresses: [overlayV4], subnetMasks: ["255.255.255.255"])
        if (cfg["exitNode"] as? Bool) ?? false {
            v4.includedRoutes = [NEIPv4Route.default()]
        } else {
            // Split-tunnel: route only the overlay ranges (never 0.0.0.0/0).
            let routes = (cfg["allowed_routes"] as? [String]) ?? (cfg["allowedRoutes"] as? [String]) ?? []
            let parsed = routes.compactMap(Self.route(from:))
            v4.includedRoutes = parsed.isEmpty
                ? [NEIPv4Route(destinationAddress: "100.64.0.0", subnetMask: "255.192.0.0")] // 100.64/10
                : parsed
        }
        if let excl = (cfg["excludeRoutes"] as? [String]), !excl.isEmpty {
            v4.excludedRoutes = excl.compactMap(Self.route(from:))
        }
        s.ipv4Settings = v4

        if let v6Addr = (cfg["iface_ipv6"] as? String), !v6Addr.isEmpty {
            let v6 = NEIPv6Settings(addresses: [v6Addr], networkPrefixLengths: [128])
            s.ipv6Settings = v6
        }

        let dns = (cfg["dns"] as? [String]).flatMap { $0.isEmpty ? nil : $0 } ?? Self.fallbackDNS
        let dnsSettings = NEDNSSettings(servers: dns)
        dnsSettings.matchDomains = [""]
        s.dnsSettings = dnsSettings
        return s
    }

    /// Parse `"ip/prefix"` or bare `"ip"` into an `NEIPv4Route`.
    private static func route(from cidr: String) -> NEIPv4Route? {
        let parts = cidr.split(separator: "/")
        guard let addr = parts.first.map(String.init), !addr.isEmpty else { return nil }
        let prefix = parts.count > 1 ? (Int(parts[1]) ?? 32) : 32
        return NEIPv4Route(destinationAddress: addr, subnetMask: mask(prefix))
    }

    private static func mask(_ prefix: Int) -> String {
        let p = max(0, min(32, prefix))
        let m = p == 0 ? 0 : (0xFFFF_FFFF << (32 - p)) & 0xFFFF_FFFF
        return "\((m >> 24) & 0xFF).\((m >> 16) & 0xFF).\((m >> 8) & 0xFF).\(m & 0xFF)"
    }

    // MARK: - utun fd discovery

    /// The packetFlow's underlying utun fd. Apple exposes no public API, so we
    /// read it via KVC (`socket.fileDescriptor`) and fall back to scanning open
    /// fds for the one bound to a `utun` control socket.
    private func utunFileDescriptor() -> Int32 {
        if let fd = packetFlow.value(forKeyPath: "socket.fileDescriptor") as? Int32, fd > 0 {
            return fd
        }
        var ctlInfo = ctl_info()
        withUnsafeMutablePointer(to: &ctlInfo.ctl_name) {
            $0.withMemoryRebound(to: CChar.self, capacity: MemoryLayout.size(ofValue: $0.pointee)) {
                _ = strcpy($0, "com.apple.net.utun_control")
            }
        }
        for fd: Int32 in 0..<1024 {
            var addr = sockaddr_ctl()
            var len = socklen_t(MemoryLayout<sockaddr_ctl>.size)
            let ok = withUnsafeMutablePointer(to: &addr) { p in
                p.withMemoryRebound(to: sockaddr.self, capacity: 1) { getpeername(fd, $0, &len) == 0 }
            }
            if ok && addr.sc_family == AF_SYSTEM && addr.ss_sysaddr == UInt32(AF_SYS_CONTROL) {
                return fd
            }
        }
        return -1
    }

    private func err(_ code: Int, _ msg: String) -> NSError {
        NSError(domain: "Fluxpeer", code: code, userInfo: [NSLocalizedDescriptionKey: msg])
    }
}
