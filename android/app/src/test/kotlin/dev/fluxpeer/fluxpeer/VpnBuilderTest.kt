// SPDX-License-Identifier: AGPL-3.0-or-later
package dev.fluxpeer.fluxpeer

import android.net.VpnService
import android.os.Build
import org.json.JSONObject
import org.junit.Test
import org.junit.runner.RunWith
import org.mockito.Mockito.*
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [28,33], manifest = Config.NONE)
class VpnBuilderTest {
    @Test fun allAppSocketsBypassByUidAndFollowDefaultNetwork() {
        val builder = mock(VpnService.Builder::class.java, RETURNS_SELF)
        val record = JSONObject("""{"exitNode":true,"excludeRoutes":["192.0.2.7"]}""")
        val config = JSONObject("""{"address_v4":"100.72.16.1","overlay_cidrs":["100.72.16.0/24"],"selected_exit":"aa"}""")
        val plan = AndroidNodeConfig.plan(record,config,Build.VERSION.SDK_INT)
        configureTun(builder,plan,"dev.fluxpeer.fluxpeer")
        verify(builder).addDisallowedApplication("dev.fluxpeer.fluxpeer")
        verify(builder,never()).setUnderlyingNetworks(any())
        verify(builder,never()).allowFamily(android.system.OsConstants.AF_INET6)
        verify(builder).addRoute("0.0.0.0",0)
        if (Build.VERSION.SDK_INT >= 33) verify(builder).excludeRoute(any(android.net.IpPrefix::class.java))
    }
}
