package com.sealctl.app

import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleOwner
import androidx.lifecycle.LifecycleRegistry
import com.sealctl.relay.ClockSkewException
import com.sealctl.relay.RateLimitedException
import com.sealctl.relay.RelayException
import java.io.IOException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.launch
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.resetMain
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.test.setMain
import kotlinx.serialization.json.JsonObject
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

/** The pace of a screen's relay checks (SPEC.md 8.1): Leave sealctl's "Hand back each computer". */
@OptIn(ExperimentalCoroutinesApi::class)
class PollingTest {
    private class Owner : LifecycleOwner {
        val registry = LifecycleRegistry.createUnsafe(this)
        override val lifecycle: Lifecycle get() = registry
    }

    private val dispatcher = StandardTestDispatcher()

    @Before
    fun main() = Dispatchers.setMain(dispatcher)

    @After
    fun reset() = Dispatchers.resetMain()

    private val down = IOException("offline")

    @Test
    fun errorsDoubleThePauseUpToTheCapAndAnAnswerResetsIt() {
        val b = PollBackoff(5_000, random = { 0.5 })
        assertEquals(5_000L, b.after(null, 0))
        assertEquals(10_000L, b.after(down, 0))
        assertEquals(20_000L, b.after(RelayException(503, "internal"), 0))
        assertEquals(40_000L, b.after(down, 0))
        assertEquals(60_000L, b.after(down, 0))
        repeat(20) { assertEquals(60_000L, b.after(down, 0)) }
        assertEquals(5_000L, b.after(null, 0))
    }

    @Test
    fun thePauseHasJitter() {
        assertEquals(8_000L, PollBackoff(5_000, random = { 0.0 }).after(down, 0))
        assertEquals(12_000L, PollBackoff(5_000, random = { 1.0 }).after(down, 0))
    }

    @Test
    fun theRateLimitWindowIsWaitedOut() {
        val b = PollBackoff(5_000, random = { 0.5 })
        assertEquals(600_000L, b.after(RateLimitedException(0, "phone", JsonObject(emptyMap())), 600_000))
        assertFalse(b.stopped)
    }

    @Test
    fun aFinalAnswerStopsTheChecks() {
        for (e in listOf(RelayException(403, "forbidden"), RelayException(400, "bad_request"), RelayException(404, "gone"),
            RelayException(401, "bad_signature"), ClockSkewException(JsonObject(emptyMap())), RelayException(0, "no_keys"))) {
            val b = PollBackoff(5_000)
            assertNull(b.after(e, 0))
            assertTrue(b.stopped)
        }
        assertFalse(Polling.isFinal(RelayException(408, "timeout")))
        assertFalse(Polling.isFinal(RelayException(500, "internal")))
    }

    @Test
    fun aKeptWindowStartsTheNextProcessInsideIt() {
        assertEquals(0L, Polling.keptWindow(until = 1_000, now = 2_000))
        assertEquals(5_000L, Polling.keptWindow(until = 5_000, now = 2_000))
        assertEquals(2_000L + Polling.KEPT_WINDOW_MS, Polling.keptWindow(until = Long.MAX_VALUE, now = 2_000))
    }

    /** A relay that keeps failing, for an hour on screen. */
    @Test
    fun aFailingRelayIsAskedLessAndLessOften() = runTest(dispatcher) {
        val owner = Owner()
        owner.registry.currentState = Lifecycle.State.RESUMED
        var calls = 0
        val job = launch {
            owner.lifecycle.pollWhileStarted(PollBackoff(5_000, random = { 0.5 }), { 0 }) { calls++; down }
        }
        runCurrent()
        assertEquals(1, calls)
        advanceTimeBy(3_600_000)
        // 10, 20, 40 s, then once a minute.
        assertTrue("$calls calls in an hour", calls in 60..65)
        job.cancel()
    }

    @Test
    fun aFinalAnswerIsNotAskedAgainWhenTheScreenComesBack() = runTest(dispatcher) {
        val owner = Owner()
        owner.registry.currentState = Lifecycle.State.RESUMED
        var calls = 0
        val backoff = PollBackoff(5_000)
        val job = launch {
            owner.lifecycle.pollWhileStarted(backoff, { 0 }) { calls++; RelayException(403, "forbidden") }
        }
        runCurrent()
        advanceTimeBy(60_000)
        assertEquals(1, calls)
        owner.registry.currentState = Lifecycle.State.CREATED
        runCurrent()
        owner.registry.currentState = Lifecycle.State.RESUMED
        runCurrent()
        advanceTimeBy(60_000)
        assertEquals(1, calls)
        job.cancel()
    }

    @Test
    fun anAnsweringRelayIsAskedEveryFiveSeconds() = runTest(dispatcher) {
        val owner = Owner()
        owner.registry.currentState = Lifecycle.State.RESUMED
        var calls = 0
        val job = launch {
            owner.lifecycle.pollWhileStarted(PollBackoff(5_000, random = { 0.5 }), { 0 }) { calls++; null }
        }
        runCurrent()
        advanceTimeBy(10_001)
        assertEquals(3, calls)
        job.cancel()
    }
}
