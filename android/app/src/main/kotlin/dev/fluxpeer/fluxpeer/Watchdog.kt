// SPDX-License-Identifier: AGPL-3.0-or-later
package dev.fluxpeer.fluxpeer

import android.content.Context
import android.content.Intent
import android.net.VpnService
import android.os.Build
import androidx.work.ExistingPeriodicWorkPolicy
import androidx.work.PeriodicWorkRequestBuilder
import androidx.work.WorkManager
import androidx.work.Worker
import androidx.work.WorkerParameters
import java.util.concurrent.TimeUnit

/**
 * Best-effort safety net for aggressive ROMs: a periodic worker that restarts
 * the tunnel if the OS killed [FluxpeerVpnService] while it should be up. The
 * foreground service + wake lock are the primary defense; this catches the
 * cases where the ROM kills us anyway. (WorkManager's min period is 15 min, so
 * recovery is coarse — it complements, not replaces, the foreground service.)
 */
class WatchdogWorker(ctx: Context, params: WorkerParameters) : Worker(ctx, params) {
    override fun doWork(): Result {
        val ctx = applicationContext
        val networkId = FluxpeerBridge.loadLastActive(ctx) // null = user stopped → leave dead
        if (networkId != null && !FluxpeerVpnService.running && VpnService.prepare(ctx) == null) {
            val svc = Intent(ctx, FluxpeerVpnService::class.java)
                .setAction(FluxpeerVpnService.ACTION_START)
                .putExtra(FluxpeerVpnService.EXTRA_NETWORK_ID, networkId)
            if (Build.VERSION.SDK_INT >= 26) ctx.startForegroundService(svc) else ctx.startService(svc)
        }
        return Result.success()
    }
}

object Watchdog {
    private const val NAME = "fluxpeer-watchdog"

    fun schedule(ctx: Context) {
        val req = PeriodicWorkRequestBuilder<WatchdogWorker>(15, TimeUnit.MINUTES).build()
        WorkManager.getInstance(ctx)
            .enqueueUniquePeriodicWork(NAME, ExistingPeriodicWorkPolicy.KEEP, req)
    }

    fun cancel(ctx: Context) {
        WorkManager.getInstance(ctx).cancelUniqueWork(NAME)
    }
}
