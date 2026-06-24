// SPDX-License-Identifier: AGPL-3.0-or-later
package dev.fluxpeer.fluxpeer

import android.net.VpnService

/**
 * JNI bridge to the FULL fluxpeer node engine (`libfp_node_mobile_sys.so`, built
 * from `engine/sys/fp-node-mobile-sys`). Unlike the old two-phase dispatcher
 * ([FluxpeerNative]), this runs the SAME engine as desktop/server: the phone is a
 * first-class mesh peer (disco / relay / multi-peer / exit-as-a-peer), not a thin
 * gateway client. We hand it the OS VPN tun fd and a node config; it pulls its peer
 * list + relays from the control-server and runs the data plane itself.
 *
 * Symbols map 1:1 to `Java_dev_fluxpeer_fluxpeer_FluxpeerNode_*` in
 * `engine/sys/fp-node-mobile-sys/src/android.rs`.
 */
object FluxpeerNode {
    init {
        System.loadLibrary("fp_node_mobile_sys")
    }

    /**
     * Run the node engine: `cfgJson` = node config
     * ({"control_server","private_key","device_id","listen_port","prefix_len"});
     * `tunFd` = the fd from `VpnService.Builder.establish()`. Returns immediately
     * with `{"ok":true}` or `{"error":"..."}`; the engine runs on its own thread
     * until [stopNode]. Idempotent-ish: call [stopNode] before re-running.
     */
    // @JvmStatic so JNI binds these as STATIC methods (2nd native arg = jclass, as the
    // Rust shim in android.rs expects). Without it, an `object`'s `external fun` is an
    // INSTANCE method (2nd arg = jobject) → "jclass has wrong type" abort at runtime.
    @JvmStatic
    external fun runNode(cfgJson: String, tunFd: Int): String

    /** Stop the running engine (signals shutdown; the tun fd is then safe to close). */
    @JvmStatic
    external fun stopNode()

    /**
     * The live VpnService, so the engine's `protectSocket` upcall can exclude its
     * egress sockets from the VPN (else our own wg packets loop back into the tun).
     */
    @Volatile
    @JvmStatic
    var vpn: VpnService? = null

    /** Engine → app upcall (JNI): exclude an egress socket fd from the VPN. */
    @JvmStatic
    fun protectSocket(fd: Int): Boolean = vpn?.protect(fd) ?: false

    /**
     * Engine → app upcall (JNI): the engine exited on its own (fatal error / lost
     * its last path), NOT via [stopNode]. The service tears down so we don't leave
     * a stale "connected" state — and the held wake lock + tun fd — behind a dead
     * engine. No-op if no service is bound.
     */
    @JvmStatic
    fun onEngineExit() {
        (vpn as? FluxpeerVpnService)?.onEngineExit()
    }
}
