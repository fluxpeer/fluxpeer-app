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

        // The gateway connect params (node_*) aren't in `/enroll`; resolve them
        // from the control-server's gateway-config endpoint and merge them in.
        if (record.optString("node_addr").isEmpty() || record.optString("node_pubkey").isEmpty()) {
            resolveGateway(record)
        }
        // Still missing → no peer in the network advertises a reachable endpoint
        // yet. Surface that clearly instead of silently failing the handshake.
        if (record.optString("node_addr").isEmpty() || record.optString("node_pubkey").isEmpty()) {
            FluxpeerBridge.emit("error", networkId = id, overlayV4 = overlayV4.ifEmpty { null })
            stopSelf()
            return
        }

        // Phase 1: handshake only.
        val req = JSONObject().apply {
            put("client_prikey", record.optString("client_prikey"))
            put("node_pubkey", record.optString("node_pubkey"))
            put("node_addr", record.optString("node_addr"))
            put("node_port", record.optInt("node_port"))
            // A user-chosen mode (anti-censorship / bonded) wins over the gateway's
            // advertised default; 'auto' leaves user_transport empty → use default.
            put("transport_protocol", record.optString("user_transport").ifEmpty { record.optString("transport_protocol", "udp") })
            put("crypto_protocol", record.optString("crypto_protocol", "noise"))
            put("iface_ipv4", overlayV4)
            record.optString("iface_ipv6").takeIf { it.isNotEmpty() }?.let { put("iface_ipv6", it) }
            record.optString("node_id").takeIf { it.isNotEmpty() }?.let { put("node_id", it) }
        }
        try {
            FluxpeerBridge.unwrap(FluxpeerNative.connectHandshakeOnly(req.toString(), this))
        } catch (e: Exception) {
            FluxpeerBridge.emit("error", networkId = id, overlayV4 = overlayV4.ifEmpty { null })
            stopSelf()
            return
        }

        // Phase 2: build the TUN and hand its fd to the engine.
        val pfd = try {
            buildTun(record, overlayV4)
        } catch (e: Exception) {
            FluxpeerNative.disconnect()
            FluxpeerBridge.emit("error", networkId = id, overlayV4 = overlayV4.ifEmpty { null })
            stopSelf()
            return
        }
        tun = pfd
        try {
            FluxpeerBridge.unwrap(FluxpeerNative.attachTun(pfd.fd))
        } catch (e: Exception) {
            teardown("error", null)
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

    /**
     * Fill the gateway connect params (node_pubkey/addr/port + routes) by asking
     * the control-server `/devices/:id/gateway`. Best-effort: on any failure the
     * record stays incomplete and `connect` reports the gap. Persists on success.
     */
    private fun resolveGateway(record: JSONObject) {
        val ctrl = record.optString("controlUrl")
        val deviceId = record.optString("deviceId")
        if (ctrl.isEmpty() || deviceId.isEmpty()) return
        try {
            val req = JSONObject().put("ctrl", ctrl).put("device_id", deviceId)
            val gw = FluxpeerBridge.unwrap(FluxpeerNative.gateway(req.toString())) as JSONObject
            record.put("node_pubkey", gw.optString("node_pubkey"))
            record.put("node_addr", gw.optString("node_addr"))
            record.put("node_port", gw.optInt("node_port"))
            gw.optString("transport_protocol").takeIf { it.isNotEmpty() }
                ?.let { record.put("transport_protocol", it) }
            gw.optJSONArray("allowed_routes")?.let { record.put("allowedRoutes", it) }
            gw.optJSONArray("dns")?.let { if (it.length() > 0) record.put("dns", it) }
            if (gw.has("mtu")) record.put("mtu", gw.optInt("mtu", record.optInt("mtu", 1380)))
            record.optString("networkId").takeIf { it.isNotEmpty() }
                ?.let { FluxpeerBridge.saveNetwork(this, it, record) }
        } catch (e: Exception) {
            // Leave node_* empty; connect() surfaces the gap.
        }
    }

    private fun buildTun(record: JSONObject, overlayV4: String): ParcelFileDescriptor {
        val b = Builder()
        b.setSession("fluxpeer")
        b.addAddress(overlayV4, 32)
        b.setMtu(record.optInt("mtu", 1380))

        // DNS (optional).
        record.optJSONArray("dns")?.let { dns ->
            for (i in 0 until dns.length()) dns.optString(i).takeIf { it.isNotEmpty() }?.let { b.addDnsServer(it) }
        }

        // Routes: full-tunnel only when exitNode; otherwise route the overlay
        // ranges (split-tunnel default — never 0.0.0.0/0 implicitly).
        if (record.optBoolean("exitNode", false)) {
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
        runCatching { FluxpeerNative.disconnect() }
        runCatching { tun?.close() }
        tun = null
        FluxpeerBridge.emit(state, networkId = id ?: networkId)
        stopForeground(STOP_FOREGROUND_REMOVE)
        stopSelf()
    }

    override fun onDestroy() {
        running = false
        releaseWakeLock()
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
