package com.sealctl.app

import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleOwner
import androidx.lifecycle.LifecycleRegistry
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.launch
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.resetMain
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.test.setMain
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Before
import org.junit.Test

/**
 * The countdowns and relay checks of an open screen (Leave every 5 s, a delay every 15 s, the
 * clocks every second) run only while the app is on screen: a stopped activity keeps its
 * composition, so a plain loop went on in the background.
 */
@OptIn(ExperimentalCoroutinesApi::class)
class WhileStartedTest {
    private class Owner : LifecycleOwner {
        val registry = LifecycleRegistry.createUnsafe(this)
        override val lifecycle: Lifecycle get() = registry
    }

    private val dispatcher = StandardTestDispatcher()

    @Before
    fun main() = Dispatchers.setMain(dispatcher)

    @After
    fun reset() = Dispatchers.resetMain()

    @Test
    fun aPollStopsWhileTheActivityIsStoppedAndRunsAgainOnReturn() = runTest(dispatcher) {
        val owner = Owner()
        owner.registry.currentState = Lifecycle.State.RESUMED
        var calls = 0
        val job = launch { owner.lifecycle.everyWhileStarted(5_000) { calls++ } }
        runCurrent()
        assertEquals(1, calls) // at once
        advanceTimeBy(10_001)
        assertEquals(3, calls) // and every 5 s

        // The app leaves the screen: an hour in the background, no call.
        owner.registry.currentState = Lifecycle.State.CREATED
        runCurrent()
        advanceTimeBy(3_600_000)
        assertEquals(3, calls)

        // Back on screen: at once, then every 5 s again.
        owner.registry.currentState = Lifecycle.State.RESUMED
        runCurrent()
        assertEquals(4, calls)
        advanceTimeBy(5_001)
        assertEquals(5, calls)

        // Paused but visible (a system prompt over the app) still counts as on screen.
        owner.registry.currentState = Lifecycle.State.STARTED
        advanceTimeBy(5_000)
        assertEquals(6, calls)

        job.cancel()
    }
}
