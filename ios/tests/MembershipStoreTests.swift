// SPDX-License-Identifier: AGPL-3.0-or-later
import Foundation

@main struct MembershipStoreTests {
    static func main() throws {
        let suite = "fluxpeer-membership-test-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else { fatalError("Test suite unavailable") }
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = MembershipStore(defaults: defaults)
        let one: [String: Any] = ["networkId": "net-1", "controlUrl": "https://a.example", "deviceId": "dev-1", "client_prikey": "private", "auth_token": "token"]
        var two = one; two["controlUrl"] = "https://b.example"
        let key = try MembershipStore.key(one)
        assert(key == "v2.aHR0cHM6Ly9hLmV4YW1wbGU.bmV0LTE.ZGV2LTE")
        let other = try MembershipStore.key(two)
        assert(key != other)
        var normalized = one; normalized["controlUrl"] = "https://A.example:443/api"
        let normalizedKey = try MembershipStore.key(normalized)
        assert(key == normalizedKey)
        normalized["deviceId"] = "dev-2"
        let deviceKey = try MembershipStore.key(normalized)
        assert(key != deviceKey)
        let legacy = String(decoding: try JSONSerialization.data(withJSONObject: one), as: UTF8.self)
        defaults.set(legacy, forKey: "network.net-1")
        defaults.set("net-1", forKey: "__last_active")
        try store.save(two) // Migrate before saving the other controller's net-1.
        assert(defaults.string(forKey: "network.net-1") == nil)
        assert(defaults.string(forKey: "__last_active") == key)
        let saved = try store.load(key)
        assert(saved?["client_prikey"] as? String == "private")
        try store.remove(key)
        let deleted = try store.load(key)
        assert(deleted == nil)
        assert(defaults.string(forKey: "__last_active") == nil)
        let retained = try store.load(other)
        assert(retained?["auth_token"] as? String == "token")
        defaults.set("broken", forKey: "network.net-2")
        do { try store.save(one); fatalError("Corrupt legacy data must fail") } catch { }
        assert(defaults.string(forKey: "network.net-2") == "broken")
        print("MembershipStore: identity, normalization, migration, scoped deletion, reconnect cleanup and corrupt-data checks passed")
    }
}
