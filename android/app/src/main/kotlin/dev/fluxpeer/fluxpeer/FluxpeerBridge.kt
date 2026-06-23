// SPDX-License-Identifier: AGPL-3.0-or-later
package dev.fluxpeer.fluxpeer

import android.content.Context
import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.EventChannel
import org.json.JSONArray
import org.json.JSONObject

/**
 * Process-wide glue between the Flutter channels (in the Activity) and the
 * [FluxpeerVpnService] (a separate component). Holds:
 *
 *  - the latest tunnel [snapshot] (source of truth for cold-start sync), and
 *  - the [EventChannel] sink that streams snapshots to Dart, and
 *  - persistence of per-network *connect records* (the private key + connect
 *    params the service needs at `start`, which never cross into Dart).
 *
 * Snapshot shape mirrors Dart `FxStateSnapshot`:
 *   {state, networkId, overlayV4, connectedAtMs, peers:[]}
 * with `state` ∈ disconnected|authorizing|connecting|connected|disconnecting|error.
 */
object FluxpeerBridge {
    private val main = Handler(Looper.getMainLooper())

    @Volatile
    var snapshot: Map<String, Any?> = mapOf("state" to "disconnected", "peers" to emptyList<Any?>())
        private set

    private var sink: EventChannel.EventSink? = null

    fun setSink(s: EventChannel.EventSink?) {
        sink = s
        // Replay the current state so a fresh listener is immediately in sync.
        if (s != null) main.post { s.success(snapshot) }
    }

    /** Update + broadcast a new snapshot (callable from any thread). */
    fun emit(
        state: String,
        networkId: String? = snapshot["networkId"] as? String,
        overlayV4: String? = snapshot["overlayV4"] as? String,
        connectedAtMs: Long? = snapshot["connectedAtMs"] as? Long,
        peers: List<Map<String, Any?>> = emptyList(),
    ) {
        val snap = mutableMapOf<String, Any?>("state" to state, "peers" to peers)
        if (networkId != null) snap["networkId"] = networkId
        if (overlayV4 != null) snap["overlayV4"] = overlayV4
        if (connectedAtMs != null) snap["connectedAtMs"] = connectedAtMs
        snapshot = snap
        main.post { sink?.success(snap) }
    }

    // ---- envelope parsing --------------------------------------------------

    /**
     * Parse an engine envelope `{"code":200,"type":"OK","result":...}` /
     * `{"code":201,"type":"Error","message":"..."}`. Returns the `result` on
     * success; throws [EngineError] with the message on failure.
     */
    fun unwrap(envelope: String): Any {
        val obj = JSONObject(envelope)
        if (obj.optInt("code") == 200) {
            return obj.opt("result") ?: JSONObject()
        }
        throw EngineError(obj.optString("message", "engine error"))
    }

    class EngineError(message: String) : Exception(message)

    // ---- connect-record persistence (SharedPreferences) --------------------
    //
    // A connect record is everything the VpnService needs to (re)build the
    // tunnel for a network without going back to Dart: the device private key,
    // overlay address, control URL, and the gateway connect params. Secrets
    // never leave the native side.

    private const val PREFS = "fluxpeer_networks"

    fun saveNetwork(ctx: Context, networkId: String, record: JSONObject) {
        ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            .edit().putString(networkId, record.toString()).apply()
    }

    fun loadNetwork(ctx: Context, networkId: String): JSONObject? {
        val raw = ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE).getString(networkId, null)
            ?: return null
        return runCatching { JSONObject(raw) }.getOrNull()
    }

    /** The network last brought up — used by [BootReceiver] to reconnect on boot. */
    fun saveLastActive(ctx: Context, networkId: String?) {
        ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit().apply {
            if (networkId == null) remove("__last_active") else putString("__last_active", networkId)
        }.apply()
    }

    fun loadLastActive(ctx: Context): String? =
        ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE).getString("__last_active", null)

    /** Build a Dart-facing `FxNetwork` map from a stored connect record. */
    fun networkToDart(record: JSONObject): Map<String, Any?> = mapOf(
        "id" to record.optString("networkId"),
        "name" to record.optString("name", "network"),
        "controlUrl" to record.optString("controlUrl", ""),
        "overlayV4" to record.optString("overlayV4").ifEmpty { null },
        "deviceId" to record.optString("deviceId").ifEmpty { null },
        "pubkey" to record.optString("pubkey").ifEmpty { null },
        "mtu" to record.optInt("mtu", 1380),
        "dns" to record.optJSONArray("dns").toStringList(),
        "exitNode" to record.optBoolean("exitNode", false),
        "excludeRoutes" to record.optJSONArray("excludeRoutes").toStringList(),
    )

    private fun JSONArray?.toStringList(): List<String> {
        if (this == null) return emptyList()
        return (0 until length()).map { optString(it) }
    }
}
