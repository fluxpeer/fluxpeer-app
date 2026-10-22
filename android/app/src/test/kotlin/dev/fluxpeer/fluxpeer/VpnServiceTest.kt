// SPDX-License-Identifier: AGPL-3.0-or-later
package dev.fluxpeer.fluxpeer

import android.content.Intent
import android.os.ParcelFileDescriptor
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [28], manifest = Config.NONE)
class VpnServiceTest {
    private val workManager = org.mockito.Mockito.mock(androidx.work.impl.WorkManagerImpl::class.java)
    @org.junit.Before fun initWorkManager() {
        androidx.work.impl.WorkManagerImpl.setDelegate(workManager)
        org.mockito.Mockito.`when`(workManager.cancelUniqueWork("fluxpeer-watchdog"))
            .thenReturn(androidx.work.impl.OperationImpl().also { it.markState(androidx.work.Operation.SUCCESS) })
    }
    @org.junit.After fun resetWorkManager() { androidx.work.impl.WorkManagerImpl.setDelegate(null) }
    class Engine : NodeBackend {
        var fd: ParcelFileDescriptor? = null
        val generations = CopyOnWriteArrayList<Long>()
        var stops = 0
        var failStop = false
        var beforeStop: () -> Unit = {}
        override fun bind(service: FluxpeerVpnService?) {}
        override fun run(config: String, fd: Int, generation: Long): String {
            this.fd = ParcelFileDescriptor.adoptFd(fd)
            generations.add(generation)
            return "{\"ok\":true}"
        }
        override fun stop() {
            beforeStop()
            check(!failStop) { "Injected native stop failure" }
            stops++; fd?.close(); fd = null
        }
    }
    private fun routes() = JSONObject("""{"address_v4":"100.72.16.1","overlay_cidrs":["100.72.16.0/24"],"dns":[],"mtu":1380,"subnets":[]}""")
    private fun record() = JSONObject("""{"networkId":"net-1","deviceId":"dev-1","controlUrl":"https://a.example","overlayV4":"100.72.16.1","client_prikey":"private","auth_token":"token"}""")
    private fun drain() { FluxpeerVpnService.drain().get(3, TimeUnit.SECONDS); shadowOf(android.os.Looper.getMainLooper()).idle() }
    private fun setup(service: FluxpeerVpnService, engine: Engine, peers: MutableList<ParcelFileDescriptor>, wait: Boolean = true): String {
        service.engine = engine
        service.scheduleWatchdog = {}
        service.establish = { val pipe = ParcelFileDescriptor.createPipe(); peers.add(pipe[1]); pipe[0] }
        val record = record(); val key = Membership.key(record)
        FluxpeerBridge.saveNetwork(service, key, record)
        FluxpeerBridge.saveEngineConfig(service, key, record, routes())
        service.onStartCommand(Intent().setAction(FluxpeerVpnService.ACTION_START).putExtra(FluxpeerVpnService.EXTRA_NETWORK_ID, key), 0, 1)
        if (!wait) return key
        drain()
        assertFalse(org.robolectric.shadows.ShadowLog.getLogs().joinToString("\n") { "${it.msg}: ${it.throwable?.stackTraceToString()}" }, engine.generations.isEmpty())
        return key
    }
    @Test fun routesRequireReadyAndRebuildRejectsPreviousGenerationCallbacks() {
        val controller = Robolectric.buildService(FluxpeerVpnService::class.java).create()
        val service = controller.get(); val engine = Engine(); val peers = mutableListOf<ParcelFileDescriptor>()
        try {
            setup(service, engine, peers)
            val first = engine.generations.single()
            assertEquals("connecting", FluxpeerBridge.snapshot["state"])
            service.onRoutes(first, routes().toString()); drain()
            assertEquals(1, engine.generations.size) // cached first report does not rebuild
            assertEquals("connecting", FluxpeerBridge.snapshot["state"])
            service.onReady(first); drain()
            assertEquals("connected", FluxpeerBridge.snapshot["state"])
            val changed = routes().put("subnets", org.json.JSONArray(listOf("192.0.2.0/24")))
            service.onRoutes(first, changed.toString()); drain()
            val second = engine.generations.last()
            assertNotEquals(first, second); assertEquals(2, engine.generations.size)
            assertEquals("connecting", FluxpeerBridge.snapshot["state"])
            service.onReady(first); service.onEngineExit(first); drain()
            assertEquals("connecting", FluxpeerBridge.snapshot["state"]); assertNotNull(engine.fd)
            service.onRoutes(second, changed.toString()); service.onReady(second); drain()
            assertEquals("connected", FluxpeerBridge.snapshot["state"])
            service.onEngineExit(second); drain(); drain()
            assertEquals("error", FluxpeerBridge.snapshot["state"]); assertNull(engine.fd)
        } finally { controller.destroy(); drain(); peers.forEach { it.close() } }
    }
    @Test fun destroyedOldServiceCannotStopReplacementOrOverwriteItsStatus() {
        val old = Robolectric.buildService(FluxpeerVpnService::class.java).create()
        val next = Robolectric.buildService(FluxpeerVpnService::class.java).create()
        val peers = mutableListOf<ParcelFileDescriptor>(); val first = Engine(); val second = Engine()
        try {
            setup(old.get(), first, peers)
            setup(next.get(), second, peers)
            val generation = second.generations.last()
            next.get().onRoutes(generation, routes().toString()); next.get().onReady(generation); drain()
            old.destroy(); drain()
            assertNotNull(second.fd); assertEquals(0, second.stops)
            assertEquals("connected", FluxpeerBridge.snapshot["state"])
        } finally { next.destroy(); drain(); peers.forEach { it.close() } }
    }
    @Test fun delayedDestroyedServiceCleanupFinishesBeforeReplacementAcquiresEngine() {
        val old = Robolectric.buildService(FluxpeerVpnService::class.java).create()
        val next = Robolectric.buildService(FluxpeerVpnService::class.java).create()
        val peers = mutableListOf<ParcelFileDescriptor>(); val first = Engine(); val second = Engine()
        val entered = CountDownLatch(1); val release = CountDownLatch(1)
        try {
            setup(old.get(), first, peers)
            first.beforeStop = { entered.countDown(); check(release.await(3, TimeUnit.SECONDS)) }
            old.destroy()
            assertTrue(entered.await(3, TimeUnit.SECONDS))
            setup(next.get(), second, peers, wait = false)
            assertTrue(second.generations.isEmpty())
            release.countDown(); drain()
            val generation = second.generations.single()
            next.get().onRoutes(generation, routes().toString()); next.get().onReady(generation); drain()
            assertNull(first.fd); assertEquals(1, first.stops)
            assertNotNull(second.fd); assertEquals(0, second.stops)
            assertEquals("connected", FluxpeerBridge.snapshot["state"])
        } finally { release.countDown(); next.destroy(); drain(); peers.forEach { it.close() } }
    }
    @Test fun leavingAnotherControllerDoesNotStopActiveMemberOrClearItsReconnectMarker() {
        val controller = Robolectric.buildService(FluxpeerVpnService::class.java).create()
        val service = controller.get(); val engine = Engine(); val peers = mutableListOf<ParcelFileDescriptor>()
        try {
            val active = setup(service, engine, peers)
            val other = record().put("controlUrl", "https://b.example"); val key = Membership.key(other)
            FluxpeerBridge.saveNetwork(service, key, other)
            val done = CountDownLatch(1); var error: Exception? = null
            FluxpeerVpnService.leave(service, key) { error = it; done.countDown() }
            assertTrue(done.await(3, TimeUnit.SECONDS)); assertNull(error)
            assertNotNull(engine.fd); assertEquals(0, engine.stops)
            assertEquals(active, FluxpeerBridge.loadLastActive(service))
            assertNotNull(FluxpeerBridge.loadNetwork(service, active)); assertNull(FluxpeerBridge.loadNetwork(service, key))
            org.mockito.Mockito.verifyNoInteractions(workManager)
        } finally { controller.destroy(); drain(); peers.forEach { it.close() } }
    }
    @Test fun failedWatchdogCancellationRetainsMembershipAndReportsFailure() {
        val controller = Robolectric.buildService(FluxpeerVpnService::class.java).create()
        val service = controller.get(); val engine = Engine(); val peers = mutableListOf<ParcelFileDescriptor>()
        try {
            val key = setup(service, engine, peers)
            org.mockito.Mockito.`when`(workManager.cancelUniqueWork("fluxpeer-watchdog"))
                .thenReturn(androidx.work.impl.OperationImpl().also { it.markState(androidx.work.Operation.State.FAILURE(java.io.IOException("cancel failed"))) })
            val done = CountDownLatch(1); var error: Exception? = null
            FluxpeerVpnService.leave(service, key) { error = it; done.countDown() }
            assertTrue(done.await(3, TimeUnit.SECONDS)); assertNotNull(error)
            assertNull(engine.fd); assertNotNull(FluxpeerBridge.loadNetwork(service, key))
            assertEquals(key, FluxpeerBridge.loadLastActive(service))
        } finally { controller.destroy(); drain(); peers.forEach { it.close() } }
    }
    @Test fun leaveWaitsForStopAndRetainsCredentialsOnCleanupFailure() {
        val controller = Robolectric.buildService(FluxpeerVpnService::class.java).create()
        val service = controller.get(); val engine = Engine(); val peers = mutableListOf<ParcelFileDescriptor>()
        try {
            val key = setup(service, engine, peers)
            engine.failStop = true
            val failed = CountDownLatch(1); var error: Exception? = null
            FluxpeerVpnService.leave(service, key) { error = it; failed.countDown() }
            assertTrue(failed.await(3, TimeUnit.SECONDS)); assertNotNull(error)
            assertNotNull(FluxpeerBridge.loadNetwork(service, key)); assertNotNull(engine.fd)
            engine.failStop = false
            assertEquals(key, FluxpeerBridge.loadLastActive(service))
            val done = CountDownLatch(1)
            FluxpeerVpnService.leave(service, key) { error = it; done.countDown() }
            assertTrue(done.await(3, TimeUnit.SECONDS)); assertNull(error)
            assertNull(engine.fd); assertNull(FluxpeerBridge.loadNetwork(service, key))
            assertNull(FluxpeerBridge.loadLastActive(service))
            org.mockito.Mockito.verify(workManager).cancelUniqueWork("fluxpeer-watchdog")
            assertNull(FluxpeerBridge.loadEngineConfig(service, key, record()))
        } finally { engine.failStop = false; controller.destroy(); drain(); peers.forEach { it.close() } }
    }
}
