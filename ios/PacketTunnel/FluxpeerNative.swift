// SPDX-License-Identifier: AGPL-3.0-or-later
import Foundation
import FluxpeerFFI

/// Swift wrapper around the fluxpeer node engine C ABI (Fluxpeer.xcframework,
/// built by `scripts/build-ios.sh`). Mirrors Android's `FluxpeerNative`.
///
/// Every call returns the engine envelope JSON:
///   {"code":200,"type":"OK","message":"","result":<...>}   on success
///   {"code":201,"type":"Error","message":"<why>"}          on failure
/// The returned `char*` is owned by us — `take` copies then `fp_free_string`s it.
enum FluxpeerNative {

    /// Transport-event sink. The engine upcalls the C callbacks below from a
    /// worker thread; they re-post as notifications the provider observes.
    static let didConnect = Notification.Name("FluxpeerDidConnect")
    static let didClose = Notification.Name("FluxpeerDidClose")

    private static func take(_ ptr: UnsafeMutablePointer<CChar>?) -> String {
        guard let ptr else { return #"{"code":201,"type":"Error","message":"null"}"# }
        defer { fp_free_string(ptr) }
        return String(cString: ptr)
    }

    /// Parse an envelope; returns `result` on code 200, else throws.
    static func unwrap(_ json: String) throws -> Any {
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let code = obj["code"] as? Int
        else { throw Err.bad("unparseable engine response") }
        if code == 200 { return obj["result"] ?? [:] }
        throw Err.bad(obj["message"] as? String ?? "engine error")
    }

    enum Err: Error { case bad(String) }

    // MARK: - calls

    static func generateKeypair() -> String { take(fp_generate_keypair()) }

    static func enroll(_ req: String) -> String { req.withCString { take(fp_enroll($0)) } }

    static func gateway(_ req: String) -> String { req.withCString { take(fp_gateway($0)) } }

    /// Phase 1: build transport + Noise handshake (no TUN). Registers the C
    /// event callbacks so the provider learns of connect / teardown.
    static func connectHandshakeOnly(_ req: String) -> String {
        req.withCString { take(fp_connect_handshake_only($0, onConnected, onClosed)) }
    }

    /// Phase 2: adopt the OS utun `fd`.
    static func attachTun(_ fd: Int32) -> String { take(fp_attach_tun(fd)) }

    static func disconnect() -> String { take(fp_disconnect()) }
}

// MARK: - C event callbacks (top-level @convention(c), no captured state)

private func onConnected(_ data: UnsafePointer<CChar>?, _ err: UnsafePointer<CChar>?) {
    // The engine into_raw'd these; the C-callback default frees them, but since
    // we route through Swift we must free what we read.
    freeIfNeeded(data); freeIfNeeded(err)
    NotificationCenter.default.post(name: FluxpeerNative.didConnect, object: nil)
}

private func onClosed(_ data: UnsafePointer<CChar>?, _ err: UnsafePointer<CChar>?) {
    let reason = err.map { String(cString: $0) } ?? ""
    freeIfNeeded(data); freeIfNeeded(err)
    NotificationCenter.default.post(name: FluxpeerNative.didClose, object: nil,
                                    userInfo: ["reason": reason])
}

private func freeIfNeeded(_ p: UnsafePointer<CChar>?) {
    if let p { fp_free_string(UnsafeMutablePointer(mutating: p)) }
}
