// SPDX-License-Identifier: AGPL-3.0-or-later
package dev.fluxpeer.fluxpeer

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.net.VpnService
import android.os.Build

/**
 * Reconnect the last-active network after a reboot, so a joined+connected device
 * comes back online automatically. Only fires if the user did NOT explicitly
 * stop the tunnel (last-active is cleared on user stop) and VPN consent is still
 * granted (it persists across reboots). The actual reconnect is the same
 * foreground-service start the UI uses.
 */
class BootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        when (intent.action) {
            Intent.ACTION_BOOT_COMPLETED,
            Intent.ACTION_LOCKED_BOOT_COMPLETED,
            "android.intent.action.QUICKBOOT_POWERON",
            -> {
                val networkId = FluxpeerBridge.loadLastActive(context) ?: return
                // Can't show consent from a receiver — only reconnect if already authorized.
                if (VpnService.prepare(context) != null) return

                val svc = Intent(context, FluxpeerVpnService::class.java)
                    .setAction(FluxpeerVpnService.ACTION_START)
                    .putExtra(FluxpeerVpnService.EXTRA_NETWORK_ID, networkId)
                if (Build.VERSION.SDK_INT >= 26) {
                    context.startForegroundService(svc)
                } else {
                    context.startService(svc)
                }
            }
        }
    }
}
