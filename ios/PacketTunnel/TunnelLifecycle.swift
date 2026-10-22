// SPDX-License-Identifier: AGPL-3.0-or-later
struct TunnelLifecycle {
    private(set) var generation: UInt64 = 0
    private(set) var active = false
    private var applied = false
    mutating func begin() -> UInt64 { generation &+= 1; active = true; applied = false; return generation }
    func accepts(_ value: UInt64) -> Bool { active && value == generation }
    mutating func routesApplied(_ value: UInt64) { if accepts(value) { applied = true } }
    func ready(_ value: UInt64) -> Bool { accepts(value) && applied }
    mutating func stop() -> UInt64 { active = false; applied = false; return generation }
}
