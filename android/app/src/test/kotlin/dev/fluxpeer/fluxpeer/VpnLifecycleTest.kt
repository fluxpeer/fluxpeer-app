// SPDX-License-Identifier: AGPL-3.0-or-later
package dev.fluxpeer.fluxpeer

import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.atomic.AtomicLong
import org.junit.Assert.*
import org.junit.Test

class VpnLifecycleTest {
    private fun CountDownLatch.ready() = assertTrue(await(2,TimeUnit.SECONDS))

    @Test fun stopInterruptsBlockedSetupInsteadOfWaitingForPollingTimeout() {
        val started = CountDownLatch(1)
        val interrupted = CountDownLatch(1)
        val stopped = CountDownLatch(1)
        val worker = Executors.newSingleThreadExecutor()
        val lifecycle = VpnLifecycle(worker, { _, _ ->
            started.countDown()
            try { CountDownLatch(1).await() } catch (_: InterruptedException) { interrupted.countDown() }
        }, { stopped.countDown() }, { _, _ -> }, {})
        try {
            lifecycle.start("one"); started.ready()
            val start = System.nanoTime()
            lifecycle.stop()
            interrupted.ready(); stopped.ready()
            assertTrue(TimeUnit.NANOSECONDS.toMillis(System.nanoTime()-start) < 1000)
        } finally { lifecycle.destroy(); worker.awaitTermination(2,TimeUnit.SECONDS) }
    }

    @Test fun startDuringCleanupIsEmittedAndStartedAfterCleanupCompletes() {
        val cleanupStarted = CountDownLatch(1)
        val releaseCleanup = CountDownLatch(1)
        val second = CountDownLatch(1)
        val events = CopyOnWriteArrayList<String>()
        val worker = Executors.newSingleThreadExecutor()
        val lifecycle = VpnLifecycle(worker, { id, _ -> if(id=="two") second.countDown() }, {
            cleanupStarted.countDown(); releaseCleanup.await()
        }, { state,id -> events.add("$state:$id") }, { events.add("idle") })
        try {
            lifecycle.start("one"); lifecycle.stop(); cleanupStarted.ready()
            lifecycle.start("two")
            assertTrue(events.contains("connecting:two"))
            assertEquals(1L,second.count)
            releaseCleanup.countDown(); second.ready()
            assertFalse(events.contains("idle"))
        } finally { releaseCleanup.countDown(); lifecycle.destroy(); worker.awaitTermination(2,TimeUnit.SECONDS) }
    }

    @Test fun serialIsInvalidatedBeforeEstablishCanDeliverOldEngineExit() {
        val ready = CountDownLatch(1)
        val value = AtomicLong()
        val worker = Executors.newSingleThreadExecutor()
        val lifecycle = VpnLifecycle(worker, { _, token -> value.set(token); ready.countDown() }, {}, { _, _ -> }, {})
        try {
            lifecycle.start("one"); ready.ready()
            val old = lifecycle.replacing()
            assertTrue(lifecycle.accepts(old))
            val next = lifecycle.replacing()
            // Simulate establish closing the previous TUN and triggering its exit.
            assertFalse(lifecycle.accepts(old))
            assertTrue(lifecycle.accepts(next))
            lifecycle.stop()
            assertFalse(lifecycle.accepts(next))
            assertFalse(lifecycle.current(value.get()))
        } finally { lifecycle.destroy(); worker.awaitTermination(2,TimeUnit.SECONDS) }
    }

    @Test fun terminalEngineExitCleansResourcesBeforeEmittingVisibleError() {
        val ready = CountDownLatch(1)
        val idle = CountDownLatch(1)
        val events = CopyOnWriteArrayList<String>()
        val worker = Executors.newSingleThreadExecutor()
        val lifecycle = VpnLifecycle(worker, { _, _ -> ready.countDown() },
            { events.add("cleanup") }, { state, _ -> events.add(state) }, { idle.countDown() })
        try {
            lifecycle.start("one"); ready.ready()
            val serial = lifecycle.replacing()
            if (lifecycle.accepts(serial)) lifecycle.stop("error")
            idle.ready()
            assertTrue(events.indexOf("cleanup") < events.indexOf("error"))
            assertEquals("error", events.last())
            assertTrue(lifecycle.isIdle())
        } finally { lifecycle.destroy(); worker.awaitTermination(2,TimeUnit.SECONDS) }
    }

    @Test fun destroyAfterCompletedStopDoesNotQueueAnotherNativeStop() {
        val idle = CountDownLatch(1)
        val cleanups = AtomicLong()
        val worker = Executors.newSingleThreadExecutor()
        val lifecycle = VpnLifecycle(worker, { _, _ -> }, { cleanups.incrementAndGet() }, { _, _ -> }, { idle.countDown() })
        lifecycle.start("one"); lifecycle.stop(); idle.ready()
        lifecycle.destroy()
        assertTrue(worker.awaitTermination(2,TimeUnit.SECONDS))
        assertEquals(1L,cleanups.get())
    }

    @Test fun temporaryNetworkUnavailabilityLeavesEngineRetryAndServiceAlive() {
        val retrying = CountDownLatch(1)
        val networkRestored = CountDownLatch(1)
        val connected = CountDownLatch(1)
        val idle = CountDownLatch(1)
        val worker = Executors.newSingleThreadExecutor()
        val lifecycle = VpnLifecycle(worker, { _, _ ->
            retrying.countDown(); networkRestored.await(); connected.countDown()
        }, {}, { _, _ -> }, { idle.countDown() })
        try {
            lifecycle.start("one"); retrying.ready()
            assertFalse(lifecycle.isIdle())
            assertEquals(1L,idle.count)
            networkRestored.countDown(); connected.ready()
            assertEquals(1L,idle.count)
        } finally { networkRestored.countDown(); lifecycle.destroy(); worker.awaitTermination(2,TimeUnit.SECONDS) }
    }
}
