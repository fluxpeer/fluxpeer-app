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
import java.util.concurrent.Executors

/** UID bypass follows the system default network; route policy comes only from the engine. */
class FluxpeerVpnService : VpnService() {
    private val main = android.os.Handler(android.os.Looper.getMainLooper())
    private val worker = Executors.newSingleThreadExecutor()
    private val lifecycle: VpnLifecycle = VpnLifecycle(worker, ::connect, ::cleanup,
        { state, id -> FluxpeerBridge.emit(state, networkId = id) },
        { main.post { if (lifecycleIdle()) { running = false; stopForeground(STOP_FOREGROUND_REMOVE); stopSelf() } } },
    )
    private fun lifecycleIdle(): Boolean = lifecycle.isIdle()
    @Volatile private var networkId: String? = null
    @Volatile private var token = 0L
    private var record: JSONObject? = null
    private var installed: AndroidNodeConfig.TunPlan? = null
    private val tunFdLock = Any()
    private var detachedTunFd = -1
    private var engineOwnsTunFd = false
    private var wakeLock: PowerManager.WakeLock? = null

    companion object {
        const val ACTION_START = "dev.fluxpeer.START"
        const val ACTION_STOP = "dev.fluxpeer.STOP"
        const val EXTRA_NETWORK_ID = "networkId"
        private const val CHANNEL_ID = "fluxpeer_tunnel"
        private const val NOTIFY_ID = 0x1f02
        @Volatile var running = false
            private set
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_STOP) {
            FluxpeerBridge.saveLastActive(this, null)
            Watchdog.cancel(this)
            lifecycle.stop()
            return START_NOT_STICKY
        }
        val id = intent?.getStringExtra(EXTRA_NETWORK_ID)
        if (id == null) {
            FluxpeerBridge.emit("error")
            lifecycle.stop("error")
            return START_NOT_STICKY
        }
        running = true
        startForeground(NOTIFY_ID, notification("Connecting…"))
        Watchdog.schedule(this)
        lifecycle.start(id)
        return START_REDELIVER_INTENT
    }

    private fun connect(id: String, value: Long) {
        try {
            networkId = id
            token = value
            val rec = FluxpeerBridge.loadNetwork(this, id) ?: error("Missing network record")
            record = rec
            val cached = FluxpeerBridge.loadEngineConfig(this, id, rec)
            install(AndroidNodeConfig.bootstrap(rec, Build.VERSION.SDK_INT, cached), AndroidNodeConfig.engine(rec), value)
            if (!lifecycle.current(value)) return
            acquireWakeLock()
            FluxpeerBridge.saveLastActive(this, id)
            // Stay connecting until the engine has successfully applied config.
        } catch (e: Exception) {
            android.util.Log.e("fluxpeer-node", "VPN setup failed", e)
            if (lifecycle.current(value)) lifecycle.stop("error")
        }
    }

    fun onRoutes(serial: Long, json: String) {
        val value = token
        lifecycle.submit(value) {
            if (!lifecycle.accepts(serial)) return@submit
            try {
                val rec = record ?: return@submit
                val config = JSONObject(json)
                val plan = AndroidNodeConfig.plan(rec, config, Build.VERSION.SDK_INT)
                networkId?.let { FluxpeerBridge.saveEngineConfig(this, it, rec, config) }
                if (!plan.sameInterface(installed)) {
                    install(plan, AndroidNodeConfig.engine(rec), value)
                    return@submit // wait for the replacement engine to confirm its applied state
                }
                if (!lifecycle.current(value)) return@submit
                val message = plan.warnings.joinToString("; ")
                updateNotification(message.ifEmpty { "Connected — ${plan.addressV4}" })
                FluxpeerBridge.emit(if (rec.optBoolean("exitNode") && !plan.fullTunnel) "connecting" else "connected",
                    networkId = networkId, overlayV4 = plan.addressV4, connectedAtMs = System.currentTimeMillis(), warning = message)
            } catch (e: Exception) {
                android.util.Log.e("fluxpeer-node", "Engine route apply failed", e)
                if (lifecycle.current(value)) lifecycle.stop("error")
            }
        }
    }

    private fun install(plan: AndroidNodeConfig.TunPlan, cfg: JSONObject, value: Long) {
        lifecycle.replacing() // fence callbacks BEFORE establish can close the old TUN
        val pfd = buildTun(plan)
        try {
            FluxpeerNode.stopNode()
            if (!lifecycle.current(value)) return
            FluxpeerNode.vpn = this
            val fd = pfd.detachFd()
            setPendingTunFd(fd)
            val result = JSONObject(FluxpeerNode.runNode(cfg.toString(), fd, lifecycle.serial()))
            check(result.optBoolean("ok", false)) { result.optString("error", "Native engine start failed") }
            markTunFdOwnedByEngine()
            installed = plan
        } finally {
            pfd.close()
            closePendingTunFd()
        }
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

    private fun setPendingTunFd(fd: Int) {
        synchronized(tunFdLock) {
            detachedTunFd = fd
            engineOwnsTunFd = false
        }
    }

    private fun markTunFdOwnedByEngine() {
        synchronized(tunFdLock) {
            engineOwnsTunFd = true
            detachedTunFd = -1
        }
    }

    private fun closePendingTunFd() {
        val fd = synchronized(tunFdLock) {
            if (engineOwnsTunFd || detachedTunFd < 0) {
                -1
            } else {
                detachedTunFd.also { detachedTunFd = -1 }
            }
        }
        if (fd >= 0) {
            runCatching { ParcelFileDescriptor.adoptFd(fd).close() }
        }
    }

    private fun buildTun(plan: AndroidNodeConfig.TunPlan): ParcelFileDescriptor {
        val builder = Builder()
        configureTun(builder, plan, packageName)
        return builder.establish() ?: error("establish() returned null (VPN not prepared?)")
    }

    fun onEngineExit(serial: Long) {
        main.post { if (lifecycle.accepts(serial)) lifecycle.stop("error") }
    }

    private fun cleanup() {
        FluxpeerNode.stopNode()
        FluxpeerNode.vpn = null
        closePendingTunFd()
        releaseWakeLock()
        installed = null
        record = null
    }

    override fun onDestroy() {
        running = false
        lifecycle.destroy()
        super.onDestroy()
    }

    override fun onRevoke() {
        lifecycle.stop()
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

/** Kept separate so Builder policy is exercised without loading native libraries. */
internal fun configureTun(builder: VpnService.Builder, plan: AndroidNodeConfig.TunPlan, packageName: String) {
    builder.setSession("fluxpeer").setMtu(plan.mtu)
    builder.addDisallowedApplication(packageName)
    // No fixed underlying network: DNS and every app UID socket follow system default.
    builder.addAddress(plan.addressV4, 32)
    plan.addressV6?.let { builder.addAddress(it, 128) }
    plan.dns.forEach { builder.addDnsServer(it) }
    plan.routes.forEach { builder.addRoute(it.address, it.length) }
    if (plan.fullTunnel) {
        android.util.Log.i("fluxpeer-node", "IPv6 egress blocked in full-tunnel (not supported yet)")
    } else builder.allowFamily(android.system.OsConstants.AF_INET6)
    if (Build.VERSION.SDK_INT >= 33) {
        plan.excludes.forEach { builder.excludeRoute(android.net.IpPrefix(java.net.InetAddress.getByName(it.address), it.length)) }
    }
}
