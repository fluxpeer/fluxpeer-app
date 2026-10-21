// SPDX-License-Identifier: AGPL-3.0-or-later
package dev.fluxpeer.fluxpeer

import java.util.concurrent.ExecutorService
import java.util.concurrent.Future
import java.util.concurrent.atomic.AtomicLong

/** Serial native ownership with interruptible jobs and a retained START during STOP. */
internal class VpnLifecycle(
    private val worker: ExecutorService,
    private val connect: (String, Long) -> Unit,
    private val cleanup: () -> Unit,
    private val emit: (String, String?) -> Unit,
    private val idle: () -> Unit,
) {
    private val lock = Any()
    private var active: String? = null
    private var pending: String? = null
    private var stopping = false
    private var destroyed = false
    private var token = 0L
    private val jobs = mutableListOf<Future<*>>()
    private val engine = AtomicLong(0)
    companion object { private val serials = AtomicLong(0) }

    fun isIdle(): Boolean = synchronized(lock) { active == null && !stopping && pending == null }
    fun current(value: Long): Boolean = synchronized(lock) { token == value && active != null && !stopping && !destroyed }
    fun accepts(serial: Long): Boolean = synchronized(lock) { active != null && !stopping && !destroyed && engine.get() == serial }
    fun serial(): Long = engine.get()
    // Must run before establish(), which can close the previous engine's TUN.
    fun replacing(): Long = serials.incrementAndGet().also { engine.set(it) }

    fun start(id: String) = synchronized(lock) {
        if (destroyed) return@synchronized
        if (stopping) {
            pending = id
            emit("connecting", id)
        } else if (active != id) {
            if (active != null) {
                pending = id
                stopLocked("disconnecting", false)
            } else startLocked(id)
        }
    }

    private fun startLocked(id: String) {
        active = id
        token += 1
        val value = token
        emit("connecting", id)
        submit(value) { connect(id, value) }
    }

    fun submit(value: Long, work: () -> Unit) = synchronized(lock) {
        if (!current(value)) return@synchronized
        jobs.removeAll { it.isDone }
        jobs.add(worker.submit { if (current(value)) work() })
    }

    fun stop(state: String = "disconnected") = synchronized(lock) { stopLocked(state, true) }

    private fun stopLocked(state: String, clearPending: Boolean) {
        if (clearPending) pending = null
        if (stopping) return
        stopping = true
        token += 1
        engine.set(0)
        val old = active
        active = null
        jobs.forEach { it.cancel(true) }
        jobs.clear()
        emit("disconnecting", old)
        worker.submit {
            try {
                cleanup()
            } finally {
                synchronized(lock) {
                    stopping = false
                    emit(state, old)
                    val next = pending
                    pending = null
                    if (!destroyed && next != null) startLocked(next) else idle()
                }
            }
        }
    }

    fun destroy() = synchronized(lock) {
        destroyed = true
        pending = null
        // Normal stop already cleaned up before stopSelf/onDestroy. A second
        // cleanup could otherwise stop a newly created service's native engine.
        if (active != null || stopping) stopLocked("disconnected", true)
        worker.shutdown()
    }
}
