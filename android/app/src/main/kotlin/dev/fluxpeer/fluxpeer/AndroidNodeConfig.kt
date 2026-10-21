// SPDX-License-Identifier: AGPL-3.0-or-later
package dev.fluxpeer.fluxpeer

import org.json.JSONObject
import java.net.InetAddress

/** One checked mapping for engine policy and platform routes. Only engine-applied routes may enable full tunnel. */
internal object AndroidNodeConfig {
    data class Prefix(val address: String, val length: Int) {
        val ipv6: Boolean get() = address.contains(':')
    }
    data class TunPlan(
        val addressV4: String, val addressV6: String?, val routes: List<Prefix>,
        val dns: List<String>, val mtu: Int, val fullTunnel: Boolean, val excludes: List<Prefix>,
        val selectedExit: String?, val warnings: List<String>,
    ) {
        /** Only Builder inputs require replacing the OS interface. */
        fun sameInterface(other: TunPlan?): Boolean = other != null &&
            addressV4 == other.addressV4 && addressV6 == other.addressV6 &&
            routes.toSet() == other.routes.toSet() && dns == other.dns && mtu == other.mtu &&
            fullTunnel == other.fullTunnel && excludes.toSet() == other.excludes.toSet()
    }

    fun engine(record: JSONObject): JSONObject = JSONObject().apply {
        for ((source, target) in listOf("client_prikey" to "private_key", "deviceId" to "device_id", "controlUrl" to "control_server")) {
            put(target, record.getString(source).also { require(it.isNotBlank()) { "Missing $source" } })
        }
        put("auth_token", record.optString("auth_token"))
        put("listen_port", record.optInt("listenPort", 41820))
        put("tun_name", "fp0")
        put("prefix_len", 32)
        put("use_exit", if (record.optBoolean("exitNode", false)) "auto" else "off")
        val mode = record.optString("user_transport", "auto").ifEmpty { "auto" }
        require(mode in setOf("auto", "anytls", "tcp-bond")) { "Unsupported transport: $mode" }
        put("force_relay", mode != "auto")
        put("relay_anytls", mode == "anytls")
        put("relay_bond", mode == "tcp-bond")
        if (record.optBoolean("mtuExplicit", record.has("mtu") && record.optInt("mtu") != 1380)) put("mtu", record.getInt("mtu"))
    }

    /** Reuse the complete engine configuration, but never authorize a cached exit. */
    fun bootstrap(record: JSONObject, api: Int, cached: JSONObject? = null): TunPlan {
        val config = cached?.let { JSONObject(it.toString()) } ?: JSONObject().apply {
            put("address_v4", record.getString("overlayV4"))
            put("overlay_cidrs", record.optJSONArray("engineOverlayCidrs") ?: org.json.JSONArray())
        }
        config.remove("selected_exit") // 0/0 still requires this engine's live selection
        return plan(record, config, api)
    }

    fun plan(record: JSONObject, config: JSONObject, api: Int = 33): TunPlan {
        val selected = config.optString("selected_exit").takeIf { it.isNotBlank() && it != "null" }
        val requested = record.optBoolean("exitNode", false)
        val full = requested && selected != null
        val address = literal(config.getString("address_v4"))
        require(!address.contains(':')) { "Missing IPv4 overlay address" }
        val routes = mutableSetOf<Prefix>()
        for (field in listOf("overlay_cidrs", "subnets")) {
            val prefixes = config.optJSONArray(field) ?: continue
            for (i in 0 until prefixes.length()) {
                val route = prefix(prefixes.getString(i))
                if (route.length != 0 && (!full || !route.ipv6)) routes.add(route)
            }
        }
        if (routes.none { contains(it, address) }) routes.add(Prefix(address, 32))
        if (full) routes.add(Prefix("0.0.0.0", 0))
        val dns = record.optJSONArray("dns")?.takeIf { it.length() > 0 } ?: config.optJSONArray("dns")
        val resolvers = (0 until (dns?.length() ?: 0)).map { literal(dns!!.getString(it)) }
            .filter { !full || !it.contains(':') }.toMutableList()
        if (full && resolvers.isEmpty()) resolvers.addAll(listOf("1.1.1.1", "8.8.8.8"))
        // Split ignores exclusions entirely, including invalid legacy entries.
        val excludes = if (full) record.optJSONArray("excludeRoutes") else null
        val excluded = (0 until (excludes?.length() ?: 0)).map { prefix(excludes!!.getString(it)) }
            .filter { !it.ipv6 }.distinct()
        val warnings = mutableListOf<String>()
        if (requested && !full) warnings.add("Full-tunnel enabled but no exit available")
        if (excluded.isNotEmpty() && api < 33) warnings.add("Route exclusions require Android 13; exclusions are inactive")
        val configuredMtu = if (record.optBoolean("mtuExplicit", record.has("mtu") && record.optInt("mtu") != 1380)) record.getInt("mtu") else config.optInt("mtu", 1380)
        val mtu = if (requested && !full) configuredMtu.coerceAtLeast(1280) else configuredMtu
        require(mtu in (if (full) 68 else 1280)..65535) { "Invalid MTU" }
        val v6 = if (full) null else config.optString("address_v6").takeIf { it.isNotEmpty() && it != "null" }?.let(::literal)
        require(v6 == null || v6.contains(':')) { "Invalid IPv6 overlay address" }
        return TunPlan(address, v6, routes.sortedWith(compareBy({ it.address }, { it.length })), resolvers.distinct(), mtu,
            full, if (api >= 33) excluded else emptyList(), if (full) selected else null, warnings)
    }

    private fun contains(prefix: Prefix, address: String): Boolean =
        prefix.ipv6 == address.contains(':') && prefix("$address/${prefix.length}") == prefix

    fun prefix(cidr: String): Prefix {
        val parts = cidr.trim().split('/')
        require(parts.size in 1..2) { "Invalid route prefix" }
        val address = literal(parts[0])
        val bytes = InetAddress.getByName(address).address
        val length = if (parts.size == 2) parts[1].toInt() else bytes.size * 8
        require(length in 0..(bytes.size * 8)) { "Invalid route prefix length" }
        for (i in bytes.indices) {
            val keep = (length - i * 8).coerceIn(0, 8)
            bytes[i] = (bytes[i].toInt() and (0xff shl (8 - keep))).toByte()
        }
        return Prefix(InetAddress.getByAddress(bytes).hostAddress ?: error("Invalid route address"), length)
    }

    private fun literal(value: String): String {
        // Reject hostnames before InetAddress can resolve them over any network.
        require(value.isNotEmpty() && (value.contains(':') && value.all { it in "0123456789abcdefABCDEF:." }
            || value.split('.').let { it.size == 4 && it.all { octet -> octet.isNotEmpty() && octet.all(Char::isDigit) && (octet.toIntOrNull() ?: -1) in 0..255 } })) { "Expected an IP literal" }
        return InetAddress.getByName(value).hostAddress ?: error("Invalid IP literal")
    }
}
