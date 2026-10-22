// SPDX-License-Identifier: AGPL-3.0-or-later
import Foundation
import Darwin

struct TunnelOptions: Decodable {
    var exitNode: Bool?; var use_exit: String?; var dns: [String]?
    var mtu: Int?; var mtuExplicit: Bool?; var excludeRoutes: [String]?; var user_transport: String?
}
struct TunnelPrefix: Equatable {
    let address: String; let length: Int; let v6: Bool
    init(_ raw: String) throws {
        let parts = raw.split(separator: "/", omittingEmptySubsequences: false)
        guard (1...2).contains(parts.count), let first = parts.first else { throw TunnelPolicy.error("Invalid prefix") }
        address = String(first); v6 = address.contains(":")
        var bytes = [UInt8](repeating: 0, count: 16)
        guard inet_pton(v6 ? AF_INET6 : AF_INET, address, &bytes) == 1 else { throw TunnelPolicy.error("Expected IP literal") }
        let maximum = v6 ? 128 : 32
        if parts.count == 2 {
            guard let value = Int(parts[1]), (0...maximum).contains(value) else { throw TunnelPolicy.error("Invalid prefix length") }
            length = value
        } else { length = maximum }
    }
    var mask: String {
        let bits: UInt32 = length == 0 ? 0 : UInt32.max << (32 - min(length, 32))
        return "\((bits >> 24) & 255).\((bits >> 16) & 255).\((bits >> 8) & 255).\(bits & 255)"
    }
}
struct TunnelPlan {
    let v4: String; let v6: String?; let routes: [TunnelPrefix]; let excludes: [TunnelPrefix]
    let dns: [String]; let mtu: Int; let full: Bool
}
enum TunnelPolicy {
    static func error(_ message: String) -> NSError { NSError(domain: "fluxpeer.tunnel", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
    static func options(_ record: [String: Any]) throws -> TunnelOptions {
        try JSONDecoder().decode(TunnelOptions.self, from: JSONSerialization.data(withJSONObject: record))
    }
    static func merge(_ saved: [String: Any], _ current: [String: Any]) throws -> [String: Any] {
        var record = saved
        for key in ["use_exit", "exitNode", "dns", "mtu", "mtuExplicit", "excludeRoutes", "user_transport"] {
            if let value = current[key] { record[key] = value }
        }
        if current["exitNode"] != nil && current["use_exit"] == nil { record.removeValue(forKey: "use_exit") }
        _ = try engine(record)
        return record
    }
    static func engine(_ record: [String: Any]) throws -> [String: Any] {
        let options = try options(record)
        var result: [String: Any] = ["listen_port": 0, "tun_name": "fp0", "prefix_len": 32, "exit_veto": true]
        for (old, new) in [("client_prikey", "private_key"), ("deviceId", "device_id"), ("controlUrl", "control_server"), ("auth_token", "auth_token")] {
            guard let value = record[old] as? String, !value.isEmpty else { throw error("Missing \(old); rejoin required") }
            result[new] = value
        }
        let mode = options.user_transport.flatMap { $0.isEmpty ? nil : $0 } ?? "auto"
        guard ["auto", "anytls", "tcp-bond"].contains(mode) else { throw error("Unsupported transport") }
        let exit = options.use_exit ?? (options.exitNode == true ? "auto" : "off")
        guard ["off", "auto"].contains(exit) || (exit.count == 64 && exit.allSatisfy { $0.isHexDigit }) else { throw error("Invalid use_exit") }
        result["use_exit"] = exit
        result["force_relay"] = mode != "auto"; result["relay_anytls"] = mode == "anytls"; result["relay_bond"] = mode == "tcp-bond"
        if let mtu = options.mtu, options.mtuExplicit ?? (mtu != 1380) {
            guard (1280...65535).contains(mtu) else { throw error("Invalid MTU") }; result["mtu"] = mtu
        }
        for dns in options.dns ?? [] { _ = try literal(dns) }
        for prefix in options.excludeRoutes ?? [] { _ = try TunnelPrefix(prefix) }
        result["dns"] = options.dns ?? []; result["exclude_routes"] = options.excludeRoutes ?? []
        return result
    }
    static func literal(_ raw: String) throws -> TunnelPrefix {
        guard !raw.contains("/") else { throw error("Expected address without prefix") }
        return try TunnelPrefix(raw)
    }
    static func plan(_ record: [String: Any], _ applied: [String: Any]) throws -> TunnelPlan {
        let options = try options(record); let engine = try engine(record)
        guard let address = applied["address_v4"] as? String, !(try literal(address)).v6 else { throw error("Missing IPv4 overlay address") }
        let selected = applied["selected_exit"] as? String
        let full = engine["use_exit"] as? String != "off" && selected?.isEmpty == false
        let prefixes = (applied["overlay_cidrs"] as? [String] ?? []) + (applied["subnets"] as? [String] ?? [])
        var routes = try prefixes.map(TunnelPrefix.init).filter { $0.length > 0 }
        if full { routes = try [TunnelPrefix("0.0.0.0/0"), TunnelPrefix("::/0")] }
        var v6 = applied["address_v6"] as? String
        if v6 == "" { v6 = nil }
        if let address = v6, !(try literal(address)).v6 { throw error("Invalid IPv6 overlay address") }
        // A local placeholder lets NE capture and discard IPv6 when the control
        // assigns only IPv4. It is never used as a server or carrier endpoint.
        if v6 == nil && routes.contains(where: { $0.v6 }) { v6 = "fd00::1" }
        let excludes = try (options.excludeRoutes ?? []).map(TunnelPrefix.init).filter { !full || !$0.v6 }
        let dns = options.dns.flatMap { $0.isEmpty ? nil : $0 } ?? (applied["dns"] as? [String] ?? [])
        for address in dns { _ = try literal(address) }
        let mtu = engine["mtu"] as? Int ?? applied["mtu"] as? Int ?? 1380
        guard (1280...65535).contains(mtu) else { throw error("Invalid applied MTU") }
        return TunnelPlan(v4: address, v6: v6, routes: routes, excludes: excludes, dns: dns, mtu: mtu, full: full)
    }
}

/// The iOS TUN codec carries a four-byte, network-order address family.
enum PacketFraming {
    static func wrap(_ packet: Data, family: UInt32, blockIPv6: Bool) -> Data? {
        guard let first = packet.first, packet.count <= 65535,
              (first >> 4 == 4 && family == AF_INET) || (first >> 4 == 6 && family == AF_INET6),
              !(blockIPv6 && first >> 4 == 6) else { return nil }
        var header = family.bigEndian
        var frame = withUnsafeBytes(of: &header) { Data($0) }; frame.append(packet); return frame
    }
    static func unwrap(_ frame: Data, blockIPv6: Bool) -> (Data, NSNumber)? {
        guard frame.count > 4 else { return nil }
        let packet = Data(frame.dropFirst(4)); guard let first = packet.first else { return nil }
        let family = first >> 4 == 4 ? AF_INET : AF_INET6
        guard let expected = wrap(packet, family: UInt32(family), blockIPv6: blockIPv6), expected == frame else { return nil }
        return (packet, NSNumber(value: family))
    }
}
