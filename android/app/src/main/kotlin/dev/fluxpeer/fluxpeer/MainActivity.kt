// SPDX-License-Identifier: AGPL-3.0-or-later
package dev.fluxpeer.fluxpeer

import android.app.Activity
import android.content.Intent
import android.net.VpnService
import android.os.Build
import android.os.Handler
import android.os.Looper
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import org.json.JSONObject
import kotlin.concurrent.thread

/**
 * Hosts the Flutter UI and bridges its channels to the native tunnel:
 *   - MethodChannel `dev.fluxpeer.app/flux`      — join / start / stop / getCurrentState
 *   - EventChannel  `dev.fluxpeer.app/fluxStatus` — live [FluxpeerBridge] snapshots
 *
 * `start` needs one-time VPN consent ([VpnService.prepare]); we launch the
 * system consent dialog and resume the start once granted.
 */
class MainActivity : FlutterActivity() {
    private val main = Handler(Looper.getMainLooper())
    private val reqVpn = 0x7f01
    private val reqVpnGrant = 0x7f02 // VPN consent from the settings UI (no auto-start)
    private val reqNotif = 0x7f03

    private var pendingStartNetworkId: String? = null
    private var pendingResult: MethodChannel.Result? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val messenger = flutterEngine.dartExecutor.binaryMessenger

        MethodChannel(messenger, "dev.fluxpeer.app/flux").setMethodCallHandler { call, result ->
            when (call.method) {
                "join" -> onJoin(call, result)
                "start" -> onStart(call, result)
                "stop" -> onStop(result)
                "getCurrentState" -> result.success(FluxpeerBridge.snapshot)
                // Keepalive / permissions (Me-tab system settings; background survival).
                "permissionStatus" -> result.success(KeepAlive.status(this))
                "requestVpn" -> requestVpn(result)
                "requestBatteryExemption" -> { KeepAlive.requestBatteryExemption(this); result.success(null) }
                "requestNotifications" -> { requestNotifications(); result.success(null) }
                "openAutoStart" -> { KeepAlive.openAutoStartSettings(this); result.success(null) }
                else -> result.notImplemented()
            }
        }

        EventChannel(messenger, "dev.fluxpeer.app/fluxStatus").setStreamHandler(
            object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) =
                    FluxpeerBridge.setSink(events)

                override fun onCancel(arguments: Any?) = FluxpeerBridge.setSink(null)
            },
        )
    }

    /** keygen → enroll → persist a connect record → return the Dart FxNetwork. */
    private fun onJoin(call: MethodCall, result: MethodChannel.Result) {
        val token = call.argument<String>("token").orEmpty()
        val device = call.argument<String>("device").orEmpty()
        thread(name = "fluxpeer-join") {
            try {
                val kp = FluxpeerBridge.unwrap(FluxpeerNative.generateKeypair()) as JSONObject
                val pub = kp.optString("public_key")
                val priv = kp.optString("private_key")

                // enroll needs the PRIVATE key for proof-of-possession (audit #11):
                // the SDK derives the public half + ECDH proof and the key never
                // leaves the native side. (wg_public_key kept for back-compat/logging.)
                val enrollReq = JSONObject()
                    .put("token", token)
                    .put("name", device.ifEmpty { "android" })
                    .put("wg_private_key", priv)
                    .put("wg_public_key", pub)
                val dev = FluxpeerBridge.unwrap(FluxpeerNative.enroll(enrollReq.toString())) as JSONObject

                val networkId = dev.optString("network_id").ifEmpty { dev.optString("id") }
                val record = JSONObject()
                    .put("networkId", networkId)
                    .put("name", device.ifEmpty { dev.optString("name", "network") })
                    .put("controlUrl", dev.optString("control_server"))
                    .put("overlayV4", dev.optString("address_v4"))
                    .put("deviceId", dev.optString("id"))
                    // Per-device auth token issued at enroll — the node sends it as the
                    // bearer on its control calls (config pull / endpoints / routes).
                    .put("auth_token", dev.optString("auth_token"))
                    .put("pubkey", pub)
                    .put("client_prikey", priv)
                    .put("transport_protocol", "udp")
                    .put("crypto_protocol", "noise")
                    .put("mtu", 1380)
                // node_* gateway connect params are NOT in /enroll yet (step-6 gap);
                // they get merged in once the control-server exposes a config fetch.

                FluxpeerBridge.saveNetwork(this, networkId, record)
                val dart = FluxpeerBridge.networkToDart(record)
                main.post { result.success(dart) }
            } catch (e: Exception) {
                main.post { result.error("join_failed", e.message, null) }
            }
        }
    }

    /** Ensure VPN consent, then launch [FluxpeerVpnService] for the network. */
    private fun onStart(call: MethodCall, result: MethodChannel.Result) {
        val networkJson = call.argument<String>("network").orEmpty()
        val passed = runCatching { JSONObject(networkJson) }.getOrNull()
        val networkId = passed?.optString("id")
        if (networkId.isNullOrEmpty()) {
            result.error("bad_args", "start: missing network id", null)
            return
        }
        // Fold the current connection-mode choice into the native record so connect
        // honors it ('' = auto → use the gateway default).
        runCatching {
            FluxpeerBridge.loadNetwork(this, networkId)?.let { rec ->
                rec.put("user_transport", passed?.optString("user_transport").orEmpty())
                FluxpeerBridge.saveNetwork(this, networkId, rec)
            }
        }

        val consent = VpnService.prepare(this)
        if (consent != null) {
            // Need one-time user consent; resume in onActivityResult.
            pendingStartNetworkId = networkId
            pendingResult = result
            startActivityForResult(consent, reqVpn)
            return
        }
        launchService(networkId)
        result.success(null)
    }

    /** Trigger the VPN-consent dialog from the settings UI (not tied to a start). */
    private fun requestVpn(result: MethodChannel.Result) {
        val consent = VpnService.prepare(this)
        if (consent == null) {
            result.success(true) // already authorized
        } else {
            startActivityForResult(consent, reqVpnGrant)
            result.success(null)
        }
    }

    private fun requestNotifications() {
        if (Build.VERSION.SDK_INT >= 33) {
            requestPermissions(arrayOf(android.Manifest.permission.POST_NOTIFICATIONS), reqNotif)
        }
    }

    private fun onStop(result: MethodChannel.Result) {
        val intent = Intent(this, FluxpeerVpnService::class.java).setAction(FluxpeerVpnService.ACTION_STOP)
        startService(intent)
        result.success(null)
    }

    private fun launchService(networkId: String) {
        val intent = Intent(this, FluxpeerVpnService::class.java)
            .setAction(FluxpeerVpnService.ACTION_START)
            .putExtra(FluxpeerVpnService.EXTRA_NETWORK_ID, networkId)
        if (Build.VERSION.SDK_INT >= 26) startForegroundService(intent) else startService(intent)
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != reqVpn) return
        val networkId = pendingStartNetworkId
        val result = pendingResult
        pendingStartNetworkId = null
        pendingResult = null
        if (resultCode == Activity.RESULT_OK && networkId != null) {
            launchService(networkId)
            result?.success(null)
        } else {
            FluxpeerBridge.emit("disconnected", networkId = networkId)
            result?.error("vpn_denied", "VPN permission denied", null)
        }
    }
}
