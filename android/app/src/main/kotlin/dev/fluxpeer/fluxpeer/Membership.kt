// SPDX-License-Identifier: AGPL-3.0-or-later
package dev.fluxpeer.fluxpeer

import android.util.Base64
import java.net.URI
import org.json.JSONObject

internal object Membership {
    fun key(record: JSONObject): String = key(record.getString("controlUrl"),
        record.optString("networkId").ifEmpty { record.getString("id") }, record.optString("deviceId"))

    fun key(control: String, network: String, device: String): String {
        val uri = URI(control)
        val scheme = uri.scheme?.lowercase()
        require(scheme == "https" || scheme == "http") { "Invalid control origin" }
        require(uri.userInfo == null && uri.host != null && network.isNotEmpty()) { "Invalid membership identity" }
        val host = uri.host.lowercase().removePrefix("[").removeSuffix("]")
        val authority = if (host.contains(':')) "[$host]" else host
        val port = if (uri.port == -1 || (scheme == "http" && uri.port == 80) || (scheme == "https" && uri.port == 443)) "" else ":${uri.port}"
        return "v2." + listOf("$scheme://$authority$port", network, device).joinToString(".") {
            Base64.encodeToString(it.toByteArray(Charsets.UTF_8), Base64.URL_SAFE or Base64.NO_WRAP or Base64.NO_PADDING)
        }
    }
}
