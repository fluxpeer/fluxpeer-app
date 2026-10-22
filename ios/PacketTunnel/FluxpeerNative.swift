// SPDX-License-Identifier: AGPL-3.0-or-later
import Foundation
import FluxpeerFFI

enum FluxpeerNative {
    private static let lock = NSLock()
    private static var receiver: ((UInt64, UInt32, String) -> Int32)?
    static func observe(_ callback: ((UInt64, UInt32, String) -> Int32)?) {
        lock.lock(); receiver = callback; lock.unlock()
    }
    static func deliver(_ generation: UInt64, _ kind: UInt32, _ data: UnsafePointer<CChar>?) -> Int32 {
        guard let data else { return -1 }
        let json = String(cString: data)
        lock.lock(); let callback = receiver; lock.unlock()
        return callback?(generation, kind, json) ?? -1
    }
    private static func take(_ pointer: UnsafeMutablePointer<CChar>?) -> String {
        guard let pointer else { return #"{"code":201,"message":"null engine result"}"# }
        defer { fp_mobile_free(pointer) }; return String(cString: pointer)
    }
    static func unwrap(_ json: String) throws -> Any {
        guard let data = json.data(using: .utf8), let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["code"] as? Int == 200 else { throw TunnelPolicy.error(json) }
        return object["result"] ?? [:]
    }
    static func generateKeypair() -> String { take(fp_mobile_keypair()) }
    static func enroll(_ request: String) -> String { request.withCString { take(fp_mobile_enroll($0)) } }
    static func start(_ config: String, fd: Int32, generation: UInt64) -> String {
        config.withCString { take(fp_mobile_start($0, fd, generation, { FluxpeerNative.deliver($0, $1, $2) })) }
    }
    static func stop(_ generation: UInt64) -> String { take(fp_mobile_stop(generation)) }
}
