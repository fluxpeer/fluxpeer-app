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
    @Synchronized fun emit(
        state: String,
        networkId: String? = snapshot["networkId"] as? String,
        overlayV4: String? = snapshot["overlayV4"] as? String,
        connectedAtMs: Long? = snapshot["connectedAtMs"] as? Long,
        peers: List<Map<String, Any?>> = emptyList(),
        warning: String? = null,
        generation: Long = (snapshot["generation"] as? Long) ?: 0L,
    ) {
        if (generation < ((snapshot["generation"] as? Long) ?: 0L)) return
        val snap = mutableMapOf<String, Any?>("state" to state, "peers" to peers, "generation" to generation)
        if (networkId != null) snap["networkId"] = networkId
        if (overlayV4 != null) snap["overlayV4"] = overlayV4
        if (connectedAtMs != null) snap["connectedAtMs"] = connectedAtMs
        if (!warning.isNullOrEmpty()) snap["warning"] = warning
        snapshot = snap
        main.post { if (snapshot === snap) sink?.success(snap) }
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

    private fun prefs(ctx: Context) = ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

    /** Migrate only records whose complete identity is available; never guess by net id. */
    @Synchronized private fun migrate(ctx: Context) {
        val prefs = prefs(ctx)
        val edit = prefs.edit()
        var changed = false
        val active = prefs.getString("__last_active", null)
        for ((old, value) in prefs.all) {
            if (old.startsWith("__") || old.startsWith("v2.") || value !is String) continue
            val record = JSONObject(value)
            val key = Membership.key(record)
            check(!prefs.contains(key) || prefs.getString(key, null) == value) { "Conflicting legacy membership; rejoin required" }
            edit.putString(key, value).remove(old)
            if (active == old) edit.putString("__last_active", key)
            changed = true
        }
        if (changed) check(edit.commit()) { "Membership migration could not be saved" }
    }

    @Synchronized fun saveNetwork(ctx: Context, networkId: String, record: JSONObject) {
        migrate(ctx)
        val key = Membership.key(record)
        check(!FluxpeerVpnService.isLeaving(key)) { "Membership leave is in progress" }
        require(networkId == key || networkId == record.optString("networkId")) { "Membership identity mismatch" }
        check(prefs(ctx).edit().putString(key, record.toString()).commit()) { "Membership could not be saved" }
    }

    @Synchronized fun loadNetwork(ctx: Context, networkId: String): JSONObject? {
        migrate(ctx)
        require(networkId.startsWith("v2.")) { "Complete membership identity required" }
        val raw = prefs(ctx).getString(networkId, null) ?: return null
        val record = JSONObject(raw)
        check(Membership.key(record) == networkId) { "Stored membership identity mismatch" }
        return record
    }

    /** Called only after the matching native engine has stopped successfully. */
    @Synchronized fun deleteNetwork(ctx: Context, key: String) {
        migrate(ctx)
        require(key.startsWith("v2.")) { "Complete membership identity required" }
        val record = loadNetwork(ctx, key)
        val cache = ctx.getSharedPreferences("fluxpeer_engine_configs", Context.MODE_PRIVATE)
        val editCache = cache.edit()
        for (storedKey in cache.all.keys) {
            val parts = runCatching { JSONArray(storedKey) }.getOrNull() ?: continue
            val cachedId = parts.optString(0)
            // Remove every cache version for this member, including a rotated
            // public key or equivalent control URL spelling, without touching
            // another controller's legacy cache for the same server network id.
            val matches = cachedId == key || (record != null && cachedId == record.optString("networkId") &&
                runCatching { Membership.key(parts.getString(1), cachedId, parts.getString(2)) }.getOrNull() == key)
            if (matches) editCache.remove(storedKey)
        }
        check(editCache.commit()) { "Engine configuration could not be removed" }
        val prefs = prefs(ctx)
        val wasActive = prefs.getString("__last_active", null) == key
        if (wasActive) Watchdog.cancelAndWait(ctx)
        val edit = prefs.edit().remove(key)
        if (wasActive) edit.remove("__last_active")
        check(edit.commit()) { "Membership credentials could not be removed" }
    }

    /** Engine cache has its own preferences and identity key; it never rewrites settings. */
    internal fun saveEngineConfig(ctx: Context, networkId: String, record: JSONObject, config: JSONObject) {
        ctx.getSharedPreferences("fluxpeer_engine_configs", Context.MODE_PRIVATE)
            .edit().putString(engineConfigKey(networkId, record), config.toString()).commit().also { check(it) { "Engine cache could not be saved" } }
    }

    internal fun loadEngineConfig(ctx: Context, networkId: String, record: JSONObject): JSONObject? {
        val cache = ctx.getSharedPreferences("fluxpeer_engine_configs", Context.MODE_PRIVATE)
        val key = engineConfigKey(networkId, record)
        val legacy = engineConfigKey(record.optString("networkId"), record)
        val raw = cache.getString(key, null) ?: (if (networkId == Membership.key(record)) cache.getString(legacy, null) else null)?.also {
            check(cache.edit().putString(key, it).remove(legacy).commit()) { "Engine cache migration could not be saved" }
        } ?: return null
        return runCatching { JSONObject(raw) }.getOrNull()
    }

    private fun engineConfigKey(networkId: String, record: JSONObject): String =
        JSONArray(listOf(networkId, record.optString("controlUrl"), record.optString("deviceId"), record.optString("pubkey"))).toString()

    /** The network last brought up — used by [BootReceiver] to reconnect on boot. */
    @Synchronized fun saveLastActive(ctx: Context, networkId: String?) {
        migrate(ctx)
        if (networkId != null) check(loadNetwork(ctx, networkId) != null) { "Cannot reconnect a missing membership" }
        val edit = prefs(ctx).edit()
        if (networkId == null) edit.remove("__last_active") else edit.putString("__last_active", networkId)
        check(edit.commit()) { "Reconnect preference could not be saved" }
    }

    @Synchronized fun loadLastActive(ctx: Context): String? {
        migrate(ctx)
        val key = prefs(ctx).getString("__last_active", null) ?: return null
        return key.takeIf { it.startsWith("v2.") && loadNetwork(ctx, it) != null }
    }

    /** Build a Dart-facing `FxNetwork` map from a stored connect record. */
    fun networkToDart(record: JSONObject): Map<String, Any?> = mapOf(
        "id" to record.optString("networkId"),
        "name" to record.optString("name", "network"),
        "controlUrl" to record.optString("controlUrl", ""),
        "overlayV4" to record.optString("overlayV4").ifEmpty { null },
        "deviceId" to record.optString("deviceId").ifEmpty { null },
        "pubkey" to record.optString("pubkey").ifEmpty { null },
        "mtu" to record.optInt("mtu", 1380),
        "mtuExplicit" to record.optBoolean("mtuExplicit", record.has("mtu") && record.optInt("mtu") != 1380),
        "dns" to record.optJSONArray("dns").toStringList(),
        "exitNode" to record.optBoolean("exitNode", false),
        "transportProtocol" to record.optString("user_transport", "auto").ifEmpty { "auto" },
        "excludeRoutes" to record.optJSONArray("excludeRoutes").toStringList(),
    )

    private fun JSONArray?.toStringList(): List<String> {
        if (this == null) return emptyList()
        return (0 until length()).map { optString(it) }
    }
}
