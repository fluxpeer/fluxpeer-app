// SPDX-License-Identifier: AGPL-3.0-or-later
package dev.fluxpeer.fluxpeer

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.Intent
import android.net.VpnService
import android.os.Build
import android.os.ParcelFileDescriptor
import android.os.PowerManager
import org.json.JSONObject
import java.util.concurrent.atomic.AtomicBoolean
import kotlin.concurrent.thread

/**
 * Runs the fluxpeer node in-process and bridges the OS TUN to the engine.
 *
 * Two-phase, mirroring the FFI contract (see ffi/android.rs):
 *   1. [FluxpeerNative.connectHandshakeOnly] — build transport + Noise handshake
 *      (NO tun yet); we register as the engine's [FluxpeerNative.EventSink].
 *   2. Build the TUN via [VpnService.Builder] (split-tunnel by default — routes
 *      the overlay, not 0.0.0.0/0 — per the fluxpeer split-tunnel rule) and
 *      [VpnService.Builder.establish] → fd → [FluxpeerNative.attachTun].
 *
 * The engine owns packet crypto/forwarding; this service owns the fd, routes,
 * and DNS. Teardown comes from `stop` (intent) or an engine close upcall.
 */
class FluxpeerVpnService : VpnService(), FluxpeerNative.EventSink {

    @Volatile
    private var tun: ParcelFileDescriptor? = null

    @Volatile
    private var networkId: String? = null

    // Singleton guard: exactly ONE engine per service instance. onStartCommand can
    // fire repeatedly (Watchdog re-schedule, START_REDELIVER redelivery, a double
    // tap, boot auto-reconnect). Without this, each fire spawns another runNode →
    // two node engines bind two wg sockets + two relay connections under the SAME
    // identity, crossing wg sessions so the peer's return traffic is delivered to
    // the wrong socket and black-holed. Set true when an engine is starting, cleared
    // on teardown/destroy (process death resets it for free → Watchdog can revive).
    private val engineActive = AtomicBoolean(false)

    // Partial wake lock so the engine's heartbeat keeps ticking under Doze / lock
    // screen on aggressive (esp. Chinese OEM) ROMs. Held only while connected.
    private var wakeLock: PowerManager.WakeLock? = null

    companion object {
        const val ACTION_START = "dev.fluxpeer.START"
        const val ACTION_STOP = "dev.fluxpeer.STOP"
        const val EXTRA_NETWORK_ID = "networkId"
        private const val CHANNEL_ID = "fluxpeer_tunnel"
        private const val NOTIFY_ID = 0x1f02

        /// Liveness flag the [WatchdogWorker] reads to detect an OS-killed service.
        @Volatile
        var running = false
            private set
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_STOP -> {
                FluxpeerBridge.saveLastActive(this, null) // user-initiated: don't auto-reconnect on boot
                Watchdog.cancel(this)
                teardown("disconnected", null)
                return START_NOT_STICKY
            }
            else -> {
                val id = intent?.getStringExtra(EXTRA_NETWORK_ID)
                if (id == null) {
                    FluxpeerBridge.emit("error")
                    stopSelf()
                    return START_NOT_STICKY
                }
                // Already have a live/starting engine? A duplicate START must be a
                // no-op, NOT a second engine (see [engineActive]). The Watchdog still
                // revives us after real process death, where engineActive starts false.
                if (!engineActive.compareAndSet(false, true)) {
                    // Still MUST call startForeground() within ~5s of every
                    // startForegroundService(), even for a duplicate START we ignore,
                    // or Android 8+ throws ForegroundServiceDidNotStartInTimeAllowed.
                    startForeground(NOTIFY_ID, notification("Connected"))
                    return START_REDELIVER_INTENT
                }
                networkId = id
                running = true
                startForeground(NOTIFY_ID, notification("Connecting…"))
                Watchdog.schedule(this) // restart us if an aggressive ROM kills us
                // Engine calls block (handshake/attach) — keep them off the main thread.
                thread(name = "fluxpeer-connect") { connect(id) }
                // REDELIVER (not STICKY): if the OS kills + restarts us, the same
                // intent (with networkId) is redelivered so we reconnect, instead
                // of a null-intent restart that would just error out.
                return START_REDELIVER_INTENT
            }
        }
    }

    private fun connect(id: String) {
        val record = FluxpeerBridge.loadNetwork(this, id)
        if (record == null) {
            FluxpeerBridge.emit("error", networkId = id)
            stopSelf()
            return
        }
        val overlayV4 = record.optString("overlayV4")
        FluxpeerBridge.emit("connecting", networkId = id, overlayV4 = overlayV4.ifEmpty { null })

        // The FULL node engine pulls its own peer list + relay directory + STUN from
        // the control-server (the phone is a first-class mesh peer, not a thin gateway
        // client), so unlike the old two-phase dispatcher we need only identity + URL.
        val ctrl = record.optString("controlUrl")
        val prikey = record.optString("client_prikey")
        val deviceId = record.optString("deviceId")
        if (ctrl.isEmpty() || prikey.isEmpty() || deviceId.isEmpty() || overlayV4.isEmpty()) {
            FluxpeerBridge.emit("error", networkId = id, overlayV4 = overlayV4.ifEmpty { null })
            stopSelf()
            return
        }

        // Build the OS TUN first: the engine adopts its fd (on Android the app — not
        // the engine — owns the VpnService, so it can't create a device itself).
        val pfd = try {
            buildTun(record, overlayV4)
        } catch (e: Exception) {
            FluxpeerBridge.emit("error", networkId = id, overlayV4 = overlayV4.ifEmpty { null })
            stopSelf()
            return
        }
        tun = pfd

        // Expose this service so the engine's `protectSocket` upcall can exclude its
        // egress sockets from the VPN (else our own wg packets loop back into the tun).
        FluxpeerNode.vpn = this

        // Node config (see node/src/config.rs::Config). `tun_name`/`prefix_len` are
        // required by the schema but unused once a fd is injected — the platform owns
        // the device's address/routes/MTU. The engine sets `tun_fd` from the fd arg.
        val cfg = JSONObject().apply {
            put("private_key", prikey)
            put("device_id", deviceId)
            put("control_server", ctrl)
            // Per-device auth token (from enroll): the engine sends it as the bearer
            // on its control-server calls, which now reject unauthenticated devices.
            record.optString("auth_token").takeIf { it.isNotEmpty() }?.let { put("auth_token", it) }
            put("listen_port", record.optInt("listenPort", 41820))
            put("tun_name", "fp0")
            put("prefix_len", 32)
            record.optInt("mtu", 0).takeIf { it > 0 }?.let { put("mtu", it) }
        }
        // Transfer fd ownership to the engine: fp-tun adopts the fd (Fd::new) and
        // closes it when the engine stops, so detachFd() here prevents the
        // ParcelFileDescriptor from double-closing the same descriptor.
        val fd = pfd.detachFd()
        val ok = try {
            JSONObject(FluxpeerNode.runNode(cfg.toString(), fd)).optBoolean("ok", false)
        } catch (e: Exception) {
            false
        }
        if (!ok) {
            // Engine never took the fd → reclaim and close it ourselves.
            runCatching { ParcelFileDescriptor.adoptFd(fd).close() }
            teardown("error", id)
            return
        }

        acquireWakeLock()
        FluxpeerBridge.saveLastActive(this, id) // remember for boot reconnect
        updateNotification("Connected — $overlayV4")
        FluxpeerBridge.emit(
            "connected",
            networkId = id,
            overlayV4 = overlayV4.ifEmpty { null },
            connectedAtMs = System.currentTimeMillis(),
        )
    }

    @Suppress("WakelockTimeout") // intentionally held for the tunnel's lifetime
    private fun acquireWakeLock() {
        if (wakeLock?.isHeld == true) return
        val pm = getSystemService(POWER_SERVICE) as PowerManager
        wakeLock = pm.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "fluxpeer:tunnel").also {
            it.setReferenceCounted(false)
            runCatching { it.acquire() }
        }
    }

    private fun releaseWakeLock() {
        runCatching { wakeLock?.takeIf { it.isHeld }?.release() }
        wakeLock = null
    }

    private fun buildTun(record: JSONObject, overlayV4: String): ParcelFileDescriptor {
        val b = Builder()
        b.setSession("fluxpeer")
        b.addAddress(overlayV4, 32)
        b.setMtu(record.optInt("mtu", 1380))

        // DNS (optional).
        var dnsCount = 0
        record.optJSONArray("dns")?.let { dns ->
            for (i in 0 until dns.length()) dns.optString(i).takeIf { it.isNotEmpty() }?.let {
                b.addDnsServer(it); dnsCount++
            }
        }

        val fullTunnel = record.optBoolean("exitNode", false)

        // Full-tunnel with no configured DNS would black-hole all name resolution: the
        // phone's normal (LAN) resolver is now routed INTO the tunnel and unreachable
        // through the exit. Fall back to a public resolver reachable via the exit so
        // names resolve. (Split-tunnel keeps using the system DNS off-tunnel.)
        if (fullTunnel && dnsCount == 0) {
            b.addDnsServer("1.1.1.1")
            b.addDnsServer("8.8.8.8")
        }

        // Routes: full-tunnel only when exitNode; otherwise route the overlay
        // ranges (split-tunnel default — never 0.0.0.0/0 implicitly).
        if (fullTunnel) {
            b.addRoute("0.0.0.0", 0)
        } else {
            val routes = record.optJSONArray("allowedRoutes")
            if (routes != null && routes.length() > 0) {
                for (i in 0 until routes.length()) addCidrRoute(b, routes.optString(i))
            } else {
                // Default mesh overlay (CGNAT range fluxpeer allocates from).
                b.addRoute("100.64.0.0", 10)
            }
        }

        // excludeRoutes need API 33; apply when available.
        if (Build.VERSION.SDK_INT >= 33) {
            record.optJSONArray("excludeRoutes")?.let { ex ->
                for (i in 0 until ex.length()) excludeCidr(b, ex.optString(i))
            }
        }

        // Don't loop our own app's traffic back through the tunnel.
        runCatching { b.addDisallowedApplication(packageName) }

        b.setBlocking(false)
        return b.establish() ?: throw IllegalStateException("establish() returned null (VPN not prepared?)")
    }

    private fun addCidrRoute(b: Builder, cidr: String) {
        val (addr, prefix) = splitCidr(cidr) ?: return
        runCatching { b.addRoute(addr, prefix) }
    }

    private fun excludeCidr(b: Builder, cidr: String) {
        val (addr, prefix) = splitCidr(cidr) ?: return
        if (Build.VERSION.SDK_INT >= 33) {
            runCatching { b.excludeRoute(android.net.IpPrefix(java.net.InetAddress.getByName(addr), prefix)) }
        }
    }

    private fun splitCidr(cidr: String): Pair<String, Int>? {
        val parts = cidr.trim().split("/")
        if (parts.isEmpty() || parts[0].isEmpty()) return null
        val prefix = parts.getOrNull(1)?.toIntOrNull() ?: 32
        return parts[0] to prefix
    }

    /** Engine upcall (worker thread): connected=true after handshake, false on close. */
    override fun onEvent(connected: Boolean, data: String, error: String) {
        if (!connected) {
            val id = networkId
            teardown(if (error.isNotEmpty()) "error" else "disconnected", id)
        }
    }

    private fun teardown(state: String, id: String?) {
        releaseWakeLock()
        engineActive.set(false) // allow a future (re)connect to start an engine
        // Stop the engine FIRST: it owns the tun fd and closes it on shutdown. Then
        // drop our (now-detached) ParcelFileDescriptor handle — close() is a no-op.
        runCatching { FluxpeerNode.stopNode() }
        FluxpeerNode.vpn = null
        runCatching { tun?.close() }
        tun = null
        FluxpeerBridge.emit(state, networkId = id ?: networkId)
        stopForeground(STOP_FOREGROUND_REMOVE)
        stopSelf()
    }

    override fun onDestroy() {
        running = false
        engineActive.set(false)
        releaseWakeLock()
        runCatching { FluxpeerNode.stopNode() }
        FluxpeerNode.vpn = null
        runCatching { tun?.close() }
        tun = null
        super.onDestroy()
    }

    override fun onRevoke() {
        // User revoked VPN consent (Settings) — tear down cleanly.
        teardown("disconnected", networkId)
        super.onRevoke()
    }

    // ---- foreground notification ------------------------------------------

    private fun notification(text: String): Notification {
        if (Build.VERSION.SDK_INT >= 26) {
            val mgr = getSystemService(NotificationManager::class.java)
            if (mgr.getNotificationChannel(CHANNEL_ID) == null) {
                mgr.createNotificationChannel(
                    NotificationChannel(CHANNEL_ID, "fluxpeer tunnel", NotificationManager.IMPORTANCE_LOW),
                )
            }
            return Notification.Builder(this, CHANNEL_ID)
                .setContentTitle("fluxpeer")
                .setContentText(text)
                .setSmallIcon(android.R.drawable.ic_lock_lock)
                .setOngoing(true)
                .build()
        }
        @Suppress("DEPRECATION")
        return Notification.Builder(this)
            .setContentTitle("fluxpeer")
            .setContentText(text)
            .setSmallIcon(android.R.drawable.ic_lock_lock)
            .setOngoing(true)
            .build()
    }

    private fun updateNotification(text: String) {
        getSystemService(NotificationManager::class.java)?.notify(NOTIFY_ID, notification(text))
    }
}
