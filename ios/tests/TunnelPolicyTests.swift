// SPDX-License-Identifier: AGPL-3.0-or-later
import Foundation
@main struct TunnelPolicyTests {
    static func main() throws {
        let saved: [String: Any] = ["client_prikey":"private", "deviceId":"d1", "controlUrl":"https://control.invalid", "auth_token":"device-token", "node_addr":"stale.invalid"]
        let record = try TunnelPolicy.merge(saved, ["exitNode":false, "mtu":1420, "dns":["192.0.2.53"], "excludeRoutes":["192.168.1.0/24","2001:db8::/32"], "user_transport":"anytls"])
        let engine = try TunnelPolicy.engine(record)
        precondition(engine["private_key"] as? String == "private" && engine["use_exit"] as? String == "off")
        precondition(engine["force_relay"] as? Bool == true && engine["relay_anytls"] as? Bool == true)
        precondition(engine["mtu"] as? Int == 1420 && engine["dns"] as? [String] == ["192.0.2.53"])
        let applied: [String:Any] = ["address_v4":"100.72.0.2", "address_v6":"fd00::2", "overlay_cidrs":["100.72.0.0/24", "fd00::/64", "0.0.0.0/0", "::/0"], "subnets":["10.0.0.0/8"], "selected_exit":String(repeating:"a", count:64), "dns":["192.0.2.54"], "mtu":1380]
        let split = try TunnelPolicy.plan(record, applied)
        precondition(!split.full && split.routes.allSatisfy { $0.length > 0 })
        precondition(split.routes.contains { $0.v6 && $0.length == 64 })
        precondition(split.excludes.contains { $0.v6 && $0.length == 32 })
        let fullRecord = try TunnelPolicy.merge(record, ["exitNode":true])
        let full = try TunnelPolicy.plan(fullRecord, applied)
        precondition(full.full && full.routes.count == 2 && full.routes.contains { $0.v6 && $0.length == 0 })
        precondition(full.excludes.allSatisfy { !$0.v6 })
        var noExit = applied; noExit.removeValue(forKey:"selected_exit")
        let unavailable = try TunnelPolicy.plan(fullRecord, noExit); precondition(!unavailable.full)
        for invalid in [["exitNode":"true"], ["mtu":true], ["dns":["host.invalid"]], ["excludeRoutes":["2001:db8::/129"]], ["user_transport":"unknown"]] as [[String:Any]] {
            do { _ = try TunnelPolicy.merge(saved, invalid); fatalError("accepted invalid settings") } catch {}
        }
        let v4 = Data([0x45, 0, 0, 20]); let v6 = Data([0x60, 0, 0, 0])
        let frame = PacketFraming.wrap(v4, family: 2, blockIPv6: true)!
        precondition(frame == Data([0, 0, 0, 2, 0x45, 0, 0, 20]))
        precondition(PacketFraming.unwrap(frame, blockIPv6: false)?.0 == v4)
        let ipv6Frame = PacketFraming.wrap(v6, family: 30, blockIPv6: false)!
        precondition(PacketFraming.unwrap(ipv6Frame, blockIPv6: false)?.0 == v6)
        precondition(PacketFraming.wrap(v6, family: 30, blockIPv6: true) == nil)
        precondition(PacketFraming.unwrap(ipv6Frame, blockIPv6: true) == nil)
        precondition(PacketFraming.unwrap(Data([0,0,0,2]), blockIPv6: false) == nil)
        precondition(PacketFraming.wrap(v6, family: 2, blockIPv6: false) == nil)
        var lifecycle = TunnelLifecycle(); let first = lifecycle.begin()
        precondition(!lifecycle.ready(first)); lifecycle.routesApplied(first); precondition(lifecycle.ready(first))
        _ = lifecycle.stop(); let second = lifecycle.begin(); lifecycle.routesApplied(first)
        precondition(!lifecycle.accepts(first) && !lifecycle.ready(second))
        lifecycle.routesApplied(second); precondition(lifecycle.ready(second)); _ = lifecycle.stop(); precondition(!lifecycle.accepts(second))
        print("TunnelPolicyTests: settings, families, split/default guard and generation lifecycle passed")
    }
}
