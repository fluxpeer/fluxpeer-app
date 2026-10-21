// SPDX-License-Identifier: AGPL-3.0-or-later
package dev.fluxpeer.fluxpeer

import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

class AndroidNodeConfigTest {
    private fun record() = JSONObject("""{"client_prikey":"00","deviceId":"d1","controlUrl":"http://control.example","overlayV4":"100.72.16.1"}""")
    private fun config(subnets: String = "\"192.168.50.0/24\"") = JSONObject("""{
        "address_v4":"100.72.16.1","address_v6":"fd00::1","overlay_cidrs":["100.72.16.0/24","fd00::/48"],
        "subnets":[$subnets],"dns":["192.0.2.53"],"mtu":1420}""")

    @Test fun exitOptInIsExplicitAndConsumerOnly() {
        assertEquals("off", AndroidNodeConfig.engine(record()).getString("use_exit"))
        val full = AndroidNodeConfig.engine(record().put("exitNode", true))
        assertEquals("auto", full.getString("use_exit"))
        assertFalse(full.has("exit_node"))
        assertEquals("http://control.example", full.getString("control_server"))
    }

    @Test fun allTransportChoicesReachTheEngine() {
        for ((mode, flags) in mapOf("auto" to listOf(false,false,false), "" to listOf(false,false,false),
            "anytls" to listOf(true,true,false), "tcp-bond" to listOf(true,false,true))) {
            val cfg = AndroidNodeConfig.engine(record().put("user_transport", mode))
            assertEquals(flags, listOf(cfg.getBoolean("force_relay"), cfg.getBoolean("relay_anytls"), cfg.getBoolean("relay_bond")))
        }
        assertThrows(IllegalArgumentException::class.java) { AndroidNodeConfig.engine(record().put("user_transport", "bogus")) }
    }

    @Test fun fullRequestWithoutSelectedExitStaysSplitAndWarns() {
        val rec = record().put("exitNode", true)
        val split = AndroidNodeConfig.plan(rec, config().put("selected_exit", JSONObject.NULL))
        assertFalse(split.fullTunnel)
        assertFalse(split.routes.any { it.length == 0 })
        assertTrue(split.warnings.any { it.contains("no exit available") })
        val full = AndroidNodeConfig.plan(rec, config().put("selected_exit", "a".repeat(64)))
        assertTrue(full.fullTunnel)
        assertTrue(full.routes.any { it.length == 0 })
        assertNotEquals(full, AndroidNodeConfig.plan(rec, config().put("selected_exit", "b".repeat(64))))
        assertFalse(AndroidNodeConfig.plan(record(), config().put("selected_exit", "a".repeat(64))).fullTunnel)
    }

    @Test fun peerChurnDoesNotChangeStableOverlayButApprovedSubnetRevocationDoes() {
        val cfg = config()
        val first = AndroidNodeConfig.plan(record(), cfg)
        cfg.put("peers", JSONArray("""[{"allowed_ips":["100.72.16.42/32"]}]"""))
        assertEquals(first, AndroidNodeConfig.plan(record(), cfg))
        assertTrue(first.routes.contains(AndroidNodeConfig.Prefix("100.72.16.0",24)))
        assertFalse(first.routes.any { it.length == 32 })
        assertNotEquals(first, AndroidNodeConfig.plan(record(), config("\"10.20.0.0/16\"")))
        assertFalse(AndroidNodeConfig.plan(record(), config("")).routes.contains(AndroidNodeConfig.Prefix("192.168.50.0",24)))
    }

    @Test fun bootstrapNeverUsesCachedSubnetsOrExit() {
        val rec = record().put("exitNode", true).put("engineOverlayCidrs", JSONArray("[\"100.72.16.0/24\"]"))
            .put("allowedRoutes", JSONArray("[\"0.0.0.0/0\",\"10.0.0.0/8\"]"))
        val plan = AndroidNodeConfig.bootstrap(rec, 28)
        assertFalse(plan.fullTunnel)
        assertEquals(listOf(AndroidNodeConfig.Prefix("100.72.16.0",24)), plan.routes)
        assertEquals(listOf(AndroidNodeConfig.Prefix("100.72.16.1",32)), AndroidNodeConfig.bootstrap(record(),28).routes)
    }

    @Test fun splitIgnoresExclusionsAndOldApiFullWarnsWithoutFailing() {
        val rec = record().put("excludeRoutes", JSONArray("[\"invalid\"]"))
        assertTrue(AndroidNodeConfig.plan(rec, config(), 28).excludes.isEmpty())
        rec.put("exitNode", true).put("excludeRoutes", JSONArray("[\"192.0.2.7\"]"))
        val fullConfig = config().put("selected_exit", "a".repeat(64))
        val old = AndroidNodeConfig.plan(rec, fullConfig,28)
        assertTrue(old.fullTunnel)
        assertTrue(old.excludes.isEmpty())
        assertTrue(old.warnings.any { it.contains("exclusions are inactive") })
        assertEquals(listOf(AndroidNodeConfig.Prefix("192.0.2.7",32)), AndroidNodeConfig.plan(rec,fullConfig,33).excludes)
        assertEquals(128, AndroidNodeConfig.prefix("fd00::7").length)
    }

    @Test fun fullTunnelBlocksIPv6AndSupportsIpv4Mtu() {
        val rec = record().put("exitNode", true).put("mtuExplicit", true).put("mtu",1200)
            .put("dns",JSONArray("[\"2001:db8::53\",\"192.0.2.53\"]"))
            .put("excludeRoutes",JSONArray("[\"2001:db8::/32\"]"))
        val plan = AndroidNodeConfig.plan(rec, config().put("selected_exit","a".repeat(64)))
        assertNull(plan.addressV6)
        assertFalse(plan.routes.any { it.ipv6 })
        assertEquals(listOf("192.0.2.53"), plan.dns)
        assertTrue(plan.excludes.isEmpty())
        assertEquals(1200, plan.mtu)
        assertEquals(1280, AndroidNodeConfig.bootstrap(rec,28).mtu)
    }

    @Test fun mtuUnsetInheritsControlAndExplicitDefaultRemainsAnOverride() {
        val rec = record().put("mtu",1380)
        assertFalse(AndroidNodeConfig.engine(rec).has("mtu"))
        assertEquals(1420, AndroidNodeConfig.plan(rec,config()).mtu)
        rec.put("mtuExplicit",true)
        assertEquals(1380, AndroidNodeConfig.engine(rec).getInt("mtu"))
        assertEquals(1380, AndroidNodeConfig.plan(rec,config()).mtu)
    }

    @Test fun completeCacheMakesFirstEngineReportReuseTheInstalledTun() {
        val rec = record()
        val cached = config().put("dns", JSONArray("[\"192.0.2.53\",\"2001:db8::53\"]"))
        val installed = AndroidNodeConfig.bootstrap(rec, 33, cached)
        val firstReport = AndroidNodeConfig.plan(rec, JSONObject(cached.toString()))
        assertTrue(firstReport.sameInterface(installed))
        assertEquals(1420, installed.mtu)
        assertNotNull(installed.addressV6)
        assertTrue(installed.routes.contains(AndroidNodeConfig.Prefix("192.168.50.0",24)))
        assertFalse(firstReport.copy(mtu = 1440).sameInterface(installed))
        assertFalse(firstReport.copy(dns = listOf("192.0.2.54")).sameInterface(installed))
        assertFalse(AndroidNodeConfig.plan(rec, config("")).sameInterface(installed))
    }

    @Test fun cachedFullPlanRequiresLiveExitButMetadataChangesDoNotRebuild() {
        val rec = record().put("exitNode", true)
        val cached = config().put("selected_exit", "a".repeat(64))
        val bootstrap = AndroidNodeConfig.bootstrap(rec, 33, cached)
        assertFalse(bootstrap.fullTunnel)
        assertFalse(bootstrap.routes.any { it.length == 0 })
        val live = AndroidNodeConfig.plan(rec, cached)
        assertFalse(live.sameInterface(bootstrap))
        assertTrue(live.copy(selectedExit = "b".repeat(64), warnings = listOf("new warning")).sameInterface(live))
        assertEquals("a".repeat(64), cached.getString("selected_exit")) // bootstrap did not mutate cache
    }

    @Test fun malformedPrefixesFailAndHostBitsAreCanonicalized() {
        for (route in listOf("mesh.example/24","10.0.0.0/33","999.0.0.0/24")) {
            assertThrows(Exception::class.java) { AndroidNodeConfig.plan(record(),config("\"$route\"")) }
        }
        assertEquals(AndroidNodeConfig.Prefix("192.168.50.0",24),AndroidNodeConfig.prefix("192.168.50.7/24"))
    }
}
