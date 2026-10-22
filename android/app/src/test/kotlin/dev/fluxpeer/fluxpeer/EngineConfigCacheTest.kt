// SPDX-License-Identifier: AGPL-3.0-or-later
package dev.fluxpeer.fluxpeer

import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [28], manifest = Config.NONE)
class EngineConfigCacheTest {
    @Test fun legacyEngineCacheMigratesWithoutCrossMembershipFallback() {
        val context = RuntimeEnvironment.getApplication()
        val record = JSONObject("""{"networkId":"net-1","deviceId":"dev-1","controlUrl":"https://a.example","pubkey":"key"}""")
        val config = JSONObject("{\"mtu\":1420}")
        FluxpeerBridge.saveEngineConfig(context, "net-1", record, config)
        val key = Membership.key(record)
        assertEquals(config.toString(), FluxpeerBridge.loadEngineConfig(context, key, record).toString())
        assertNull(FluxpeerBridge.loadEngineConfig(context, "net-1", record))
        val other = JSONObject(record.toString()).put("controlUrl", "https://b.example")
        assertNull(FluxpeerBridge.loadEngineConfig(context, Membership.key(other), other))
    }
    @Test fun engineCacheCannotOverwriteSettingsMergedDuringConnection() {
        val context = RuntimeEnvironment.getApplication()
        val old = JSONObject("""{"networkId":"network","deviceId":"device-one","controlUrl":"http://control.example","pubkey":"key-one","exitNode":false}""")
        FluxpeerBridge.saveNetwork(context,"network",old)
        val edited = JSONObject(old.toString()).put("exitNode",true).put("mtu",1440)
            .put("mtuExplicit",true).put("user_transport","anytls")
        FluxpeerBridge.saveNetwork(context,"network",edited)
        val config = JSONObject("""{"address_v4":"100.72.16.1","address_v6":"fd00::1","dns":["192.0.2.53"],"mtu":1420,"overlay_cidrs":["100.72.16.0/24"],"subnets":[]}""")
        FluxpeerBridge.saveEngineConfig(context,"network",old,config)
        assertEquals(edited.toString(),FluxpeerBridge.loadNetwork(context,Membership.key(old)).toString())
        assertEquals(config.toString(),FluxpeerBridge.loadEngineConfig(context,"network",edited).toString())
        assertNull(FluxpeerBridge.loadEngineConfig(context,"network",JSONObject(edited.toString()).put("deviceId","new-device")))
        assertNull(FluxpeerBridge.loadEngineConfig(context,"other-network",edited))
    }
}
