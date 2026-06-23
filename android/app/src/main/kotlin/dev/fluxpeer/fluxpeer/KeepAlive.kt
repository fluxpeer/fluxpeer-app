// SPDX-License-Identifier: AGPL-3.0-or-later
package dev.fluxpeer.fluxpeer

import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.net.VpnService
import android.os.Build
import android.os.PowerManager
import android.provider.Settings
import androidx.core.app.NotificationManagerCompat

/**
 * Background-survival helpers for aggressive ROMs (especially Chinese OEMs:
 * MIUI/HyperOS, ColorOS, OriginOS/FuntouchOS, EMUI/MagicOS). The foreground
 * VpnService + partial wake lock + engine heartbeat keep the tunnel up *while
 * allowed to run*; these two user-granted exemptions stop the ROM from freezing
 * or killing us in the first place. They require a user tap — there is no
 * programmatic grant. See `fluxpeer-keepalive-playbook` memory.
 */
object KeepAlive {

    /** VPN profile authorized (VpnService consent already granted). */
    fun vpnAuthorized(ctx: Context): Boolean = VpnService.prepare(ctx) == null

    /** Notifications enabled (needed for the persistent foreground notification). */
    fun notificationsEnabled(ctx: Context): Boolean =
        if (Build.VERSION.SDK_INT >= 33) {
            ctx.checkSelfPermission(android.Manifest.permission.POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED
        } else {
            NotificationManagerCompat.from(ctx).areNotificationsEnabled()
        }

    /**
     * Status of every keep-alive-relevant permission, for the Me-tab settings.
     * `true`=on, `false`=off, `null`=can't query (autostart — ROM-private).
     */
    fun status(ctx: Context): Map<String, Any?> = mapOf(
        "vpn" to vpnAuthorized(ctx),
        "battery" to isIgnoringBatteryOptimizations(ctx),
        "notifications" to notificationsEnabled(ctx),
        "autostart" to null,
    )

    /** True if the app is exempt from Doze battery optimization. */
    fun isIgnoringBatteryOptimizations(ctx: Context): Boolean {
        if (Build.VERSION.SDK_INT < 23) return true
        val pm = ctx.getSystemService(Context.POWER_SERVICE) as PowerManager
        return pm.isIgnoringBatteryOptimizations(ctx.packageName)
    }

    /** System dialog to add the app to the battery-optimization allowlist. */
    @Suppress("BatteryLife")
    fun requestBatteryExemption(ctx: Context) {
        if (isIgnoringBatteryOptimizations(ctx)) return
        runCatching {
            ctx.startActivity(
                Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS, Uri.parse("package:${ctx.packageName}"))
                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
            )
        }.onFailure { openBatterySettings(ctx) }
    }

    private fun openBatterySettings(ctx: Context) {
        runCatching {
            ctx.startActivity(
                Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
            )
        }
    }

    /**
     * Open the OEM "auto-start / background-run allowlist" screen so the user can
     * permit fluxpeer to keep running. The component names below are the
     * dontkillmyapp.com canonical deep-links; we try each, falling back to the
     * app-details settings page.
     */
    fun openAutoStartSettings(ctx: Context) {
        val candidates = listOf(
            // Xiaomi / Redmi / POCO (MIUI / HyperOS)
            "com.miui.securitycenter" to "com.miui.permcenter.autostart.AutoStartManagementActivity",
            // OPPO / Realme / OnePlus (ColorOS) — multiple ColorOS versions
            "com.coloros.safecenter" to "com.coloros.safecenter.permission.startup.StartupAppListActivity",
            "com.coloros.safecenter" to "com.coloros.safecenter.startupapp.StartupAppListActivity",
            "com.oppo.safe" to "com.oppo.safe.permission.startup.StartupAppListActivity",
            "com.coloros.oppoguardelf" to "com.coloros.powermanager.fuelgaue.PowerUsageModelActivity",
            // vivo / iQOO (OriginOS / FuntouchOS)
            "com.vivo.permissionmanager" to "com.vivo.permissionmanager.activity.BgStartUpManagerActivity",
            "com.iqoo.secure" to "com.iqoo.secure.ui.phoneoptimize.BgStartUpManager",
            // Huawei / Honor (EMUI / MagicOS)
            "com.huawei.systemmanager" to "com.huawei.systemmanager.startupmgr.ui.StartupNormalAppListActivity",
            "com.huawei.systemmanager" to "com.huawei.systemmanager.optimize.process.ProtectActivity",
            // Samsung
            "com.samsung.android.lool" to "com.samsung.android.sm.ui.battery.BatteryActivity",
            // Letv / OnePlus older / Asus / Meizu commonly fall through to app details
        )
        for ((pkg, cls) in candidates) {
            val intent = Intent().setComponent(ComponentName(pkg, cls)).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            if (ctx.packageManager.resolveActivity(intent, 0) != null && runCatching { ctx.startActivity(intent); true }.getOrDefault(false)) {
                return
            }
        }
        // Fallback: the app's own settings page (manual allowlisting from there).
        runCatching {
            ctx.startActivity(
                Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.parse("package:${ctx.packageName}"))
                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
            )
        }
    }
}
