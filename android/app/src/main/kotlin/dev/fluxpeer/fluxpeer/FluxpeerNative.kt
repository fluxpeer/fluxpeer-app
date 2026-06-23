// SPDX-License-Identifier: AGPL-3.0-or-later
package dev.fluxpeer.fluxpeer

/**
 * JNI bridge to the in-process fluxpeer node engine
 * (`libfp_node_client_sys.so`, built by `scripts/build-android.sh` into
 * `jniLibs/<abi>/`). Each `external fun` maps 1:1 to a
 * `Java_dev_fluxpeer_fluxpeer_FluxpeerNative_*` shim in the engine
 * (`engine/sys/fp-node-client-sys/src/ffi/android.rs`).
 *
 * Every call returns a JSON envelope string:
 *   {"code":200,"type":"OK","message":"","result":<...>}   on success
 *   {"code":201,"type":"Error","message":"<why>"}          on failure
 *
 * Tunnel flow (driven by the [VpnService]):
 *   1. [generateKeypair] once per device; persist the private half.
 *   2. [enroll] a join token → overlay address + control_server.
 *   3. [connectHandshakeOnly] (no TUN yet) — proves the node reachable.
 *   4. VpnService.Builder.establish() → ParcelFileDescriptor.fd.
 *   5. [attachTun] that fd → data plane live.
 *   6. [disconnect] on teardown.
 */
object FluxpeerNative {
    init {
        System.loadLibrary("fp_node_client_sys")
    }

    /**
     * Transport-event sink. The engine upcalls this from a worker thread:
     * `connected = true` once the Noise handshake completes, then
     * `connected = false` when the transport closes (`error` carries the
     * reason JSON, empty on a clean close). Implemented by the VpnService so it
     * can tear the tunnel down when the engine reports the peer gone.
     */
    interface EventSink {
        fun onEvent(connected: Boolean, data: String, error: String)
    }

    /** x25519 keypair: result = {"private_key":"<hex>","public_key":"<hex>"}. */
    external fun generateKeypair(): String

    /**
     * Phase 1: build transport + Noise handshake (no TUN). `req` is the
     * ClientStartReq JSON; `sink` (nullable) receives [EventSink] upcalls.
     */
    external fun connectHandshakeOnly(req: String, sink: EventSink?): String

    /** Phase 2: adopt the OS TUN `fd` (from VpnService.establish()). */
    external fun attachTun(fd: Int): String

    /** Tear down the tunnel (idempotent). */
    external fun disconnect(): String

    /**
     * Enroll a join token: `req` =
     * {"token":"fp://join/<b64>","name":"...","wg_public_key":"<hex>"}
     * (or {"ctrl","code",...}). result = device identity + control_server.
     */
    external fun enroll(req: String): String

    /**
     * Resolve gateway connect params (the node_* `enroll` can't provide):
     * `req` = {"ctrl":"<control-server>","device_id":"<id>"}. result =
     * {node_pubkey, node_addr, node_port, transport_protocol, allowed_routes, …}.
     */
    external fun gateway(req: String): String
}
