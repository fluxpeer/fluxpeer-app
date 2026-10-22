// SPDX-License-Identifier: AGPL-3.0-or-later
import Foundation

/// A local key identifies both the control origin and the enrolled device.
struct MembershipStore {
    let defaults: UserDefaults

    static func key(_ record: [String: Any]) throws -> String {
        guard let control = record["controlUrl"] as? String,
              let url = URLComponents(string: control),
              let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = url.host?.lowercased(), !host.isEmpty, url.user == nil, url.password == nil,
              let network = (record["networkId"] ?? record["id"]) as? String, !network.isEmpty
        else { throw failure("Invalid membership identity") }
        let port = url.port
        let suffix = port == nil || (scheme == "http" && port == 80) || (scheme == "https" && port == 443) ? "" : ":\(port ?? 0)"
        let authority = host.contains(":") && !host.hasPrefix("[") ? "[\(host)]" : host
        let parts = ["\(scheme)://\(authority)\(suffix)", network, record["deviceId"] as? String ?? ""]
        return "v2." + parts.map {
            Data($0.utf8).base64EncodedString().replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        }.joined(separator: ".")
    }
    static func failure(_ message: String) -> NSError { NSError(domain: "fluxpeer.membership", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }

    func migrate() throws {
        // Validate all copies before replacing any legacy key. Ambiguous data is
        // surfaced instead of choosing a different controller's same network id.
        var moves: [(String, String, String)] = []
        for (old, value) in defaults.dictionaryRepresentation() where old.hasPrefix("network.") && !old.hasPrefix("network.v2.") {
            guard let raw = value as? String, let data = raw.data(using: .utf8),
                  let record = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { throw Self.failure("Invalid legacy membership") }
            let key = try Self.key(record)
            if let existing = defaults.string(forKey: "network.\(key)"), existing != raw {
                throw Self.failure("Conflicting legacy membership; rejoin required")
            }
            moves.append((old, key, raw))
        }
        for (old, key, raw) in moves {
            defaults.set(raw, forKey: "network.\(key)")
            defaults.removeObject(forKey: old)
            if defaults.string(forKey: "__last_active") == String(old.dropFirst("network.".count)) {
                defaults.set(key, forKey: "__last_active")
            }
        }
        if !moves.isEmpty { try sync() }
    }
    func load(_ key: String) throws -> [String: Any]? {
        try migrate()
        guard key.hasPrefix("v2.") else { throw Self.failure("Complete membership identity required") }
        guard let raw = defaults.string(forKey: "network.\(key)"), let data = raw.data(using: .utf8) else { return nil }
        guard let record = try JSONSerialization.jsonObject(with: data) as? [String: Any], try Self.key(record) == key
        else { throw Self.failure("Stored membership identity mismatch") }
        return record
    }
    func save(_ record: [String: Any]) throws {
        try migrate()
        let data = try JSONSerialization.data(withJSONObject: record)
        defaults.set(String(decoding: data, as: UTF8.self), forKey: "network.\(try Self.key(record))")
        try sync()
    }
    func remove(_ key: String) throws {
        try migrate()
        defaults.removeObject(forKey: "network.\(key)")
        if defaults.string(forKey: "__last_active") == key { defaults.removeObject(forKey: "__last_active") }
        try sync()
    }
    private func sync() throws {
        if !defaults.synchronize() { throw Self.failure("Membership preferences could not be saved") }
    }
}
