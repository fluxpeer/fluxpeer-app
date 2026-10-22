// SPDX-License-Identifier: AGPL-3.0-or-later
package dev.fluxpeer.fluxpeer

import android.content.Context
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [28], manifest = Config.NONE)
class MembershipTest {
    private fun record(control: String, device: String = "dev-1") = JSONObject()
        .put("networkId", "net-1").put("controlUrl", control).put("deviceId", device)
        .put("client_prikey", "private-fixture").put("auth_token", "token-fixture")

    @Test fun identitySeparatesControllersAndDevicesAndMatchesDart() {
        val one = Membership.key(record("https://a.example"))
        assertEquals("v2.aHR0cHM6Ly9hLmV4YW1wbGU.bmV0LTE.ZGV2LTE", one)
        assertEquals(one, Membership.key(record("https://A.example:443/api")))
        assertNotEquals(one, Membership.key(record("https://b.example")))
        assertNotEquals(one, Membership.key(record("https://a.example", "dev-2")))
    }
    @Test fun legacyMigrationPrecedesNewControllerSaveAndLeaveOnlyDeletesOwnSecrets() {
        val context = RuntimeEnvironment.getApplication()
        val prefs = context.getSharedPreferences("fluxpeer_networks", Context.MODE_PRIVATE)
        val old = record("https://a.example")
        val other = record("https://b.example")
        prefs.edit().clear().putString("net-1", old.toString()).putString("__last_active", "net-1").commit()
        FluxpeerBridge.saveNetwork(context, "net-1", other)
        assertFalse(prefs.contains("net-1"))
        val key = Membership.key(old)
        assertEquals(key, FluxpeerBridge.loadLastActive(context))
        assertEquals(old.toString(), FluxpeerBridge.loadNetwork(context, key).toString())
        assertEquals(other.toString(), FluxpeerBridge.loadNetwork(context, Membership.key(other)).toString())
        FluxpeerBridge.saveLastActive(context, Membership.key(other))
        FluxpeerBridge.saveEngineConfig(context, key, old, JSONObject("{\"dns\":[\"192.0.2.53\"]}"))
        val rotated = JSONObject(old.toString()).put("pubkey", "rotated-public-key").put("controlUrl", "https://A.example:443/api")
        FluxpeerBridge.saveEngineConfig(context, key, rotated, JSONObject("{\"mtu\":1420}"))
        FluxpeerBridge.saveEngineConfig(context, "net-1", old, JSONObject("{\"mtu\":1400}"))
        FluxpeerBridge.saveEngineConfig(context, "net-1", other, JSONObject("{\"mtu\":1380}"))
        FluxpeerBridge.deleteNetwork(context, key)
        assertNull(FluxpeerBridge.loadNetwork(context, key))
        assertNull(FluxpeerBridge.loadEngineConfig(context, key, old))
        assertNull(FluxpeerBridge.loadEngineConfig(context, key, rotated))
        assertNotNull(FluxpeerBridge.loadEngineConfig(context, Membership.key(other), other))
        assertNotNull(FluxpeerBridge.loadNetwork(context, Membership.key(other)))
        assertEquals(Membership.key(other), FluxpeerBridge.loadLastActive(context))
    }
    @Test fun foreignIdentityAndCorruptLegacyAreErrorsNotCrossControllerFallbacks() {
        val context = RuntimeEnvironment.getApplication()
        val prefs = context.getSharedPreferences("fluxpeer_networks", Context.MODE_PRIVATE)
        val one = record("https://a.example")
        prefs.edit().clear().putString(Membership.key(one), record("https://b.example").toString()).commit()
        assertThrows(IllegalStateException::class.java) { FluxpeerBridge.loadNetwork(context, Membership.key(one)) }
        prefs.edit().clear().putString("net-1", "broken").commit()
        assertThrows(org.json.JSONException::class.java) { FluxpeerBridge.saveNetwork(context, "net-1", one) }
        assertEquals("broken", prefs.getString("net-1", null))
    }
}
