package com.sealctl.app

import com.sealctl.core.app.DelayPhase
import com.sealctl.core.app.DelayedAction
import com.sealctl.core.app.delayPhase
import com.sealctl.core.app.runningPhoneAction
import java.util.concurrent.atomic.AtomicInteger
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.async
import kotlinx.coroutines.test.runTest
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Before
import org.junit.Test

/**
 * The "Ready" alarm at the end of a level 3 delay on the phone (SPEC.md 10.2), the phases its
 * screen follows, and one start at a time (SPEC.md 11.23). The phases come from the shared
 * crate, as the screens get them.
 */
class ReadyTest {
    /** The alarms set and cancelled, through the seam the app sets to AlarmManager. */
    private class Recorder(var exactAllowed: Boolean) : ReadyAlarms {
        val set = mutableListOf<Triple<String, Long, Boolean>>()
        val cancelled = mutableListOf<String>()
        override fun canExact() = exactAllowed
        override fun set(id: String, what: String, at: Long, exact: Boolean) { set += Triple(id, at, exact) }
        override fun cancel(id: String) { cancelled += id }
    }

    private val release = 100_000_000L
    private val expires = release + 3_600_000

    private fun action(id: String, what: String = "words", state: String = "waiting", machine: String? = null, releaseAt: Long = release) =
        DelayedAction(id, what, machine, releaseAt.toULong(), (releaseAt + 3_600_000).toULong(), state, null, (releaseAt - 7_200_000).toULong())

    private lateinit var alarms: Recorder

    @Before
    fun seam() {
        alarms = Recorder(exactAllowed = true)
        Ready.alarms = alarms
    }

    @After
    fun noSeam() {
        Ready.alarms = null
    }

    @Test
    fun theAlarmIsExactWhenAllowedAndStillFiresInDozeWhenNot() {
        Ready.schedule("a", "words", release)
        alarms.exactAllowed = false
        Ready.schedule("b", "delete", release)
        assertEquals(listOf(Triple("a", release, true), Triple("b", release, false)), alarms.set)
    }

    @Test
    fun aCancelTakesTheAlarmBack() {
        Ready.schedule("a", "words", release)
        Ready.cancel("a")
        assertEquals(listOf("a"), alarms.cancelled)
    }

    /** After a reboot, an update or a force stop: each own action still waiting gets its alarm again. */
    @Test
    fun restoreSetsTheWaitingOnesAndReportsTheReadyOnes() {
        val list = listOf(
            action("waiting"),
            action("ready", releaseAt = release - 60_000),
            action("expired", releaseAt = release - 4 * 3_600_000),
            action("cancelled", state = "cancelled"),
            action("other", what = Texts.OTHER_DEVICE),
            action("machine", what = "unseal_all", machine = "m1"),
            action("place", what = Texts.PLACE, releaseAt = release + 5_000),
        )
        val due = Ready.restore(list, release - 1_000)
        // Trusting a place gets its alarm too: it makes the app ask the relay to confirm it.
        assertEquals(listOf(Triple("waiting", release, true), Triple("place", release + 5_000, true)), alarms.set)
        assertEquals(listOf("ready"), due)
        // Ended ones have no alarm left behind.
        assertEquals(listOf("expired", "cancelled"), alarms.cancelled)
    }

    /** Open at releaseAt, the screen turns ready without the notification; after expires, start again. */
    @Test
    fun theScreenFollowsTheClock() {
        val d = action("a")
        assertEquals(DelayPhase.WAITING, delayPhase(d, (release - 1).toULong()))
        assertEquals(DelayPhase.READY, delayPhase(d, release.toULong()))
        assertEquals(DelayPhase.READY, delayPhase(d.copy(state = "released"), (expires - 1).toULong()))
        assertEquals(DelayPhase.EXPIRED, delayPhase(d.copy(state = "released"), expires.toULong()))
        assertEquals(DelayPhase.EXPIRED, delayPhase(d.copy(state = "gone"), release.toULong()))
    }

    /** The start button of a kind shows the one still waiting or ready; an expired one starts anew. */
    @Test
    fun aRunningActionIsShownInsteadOfStartingAnother() {
        val list = listOf(action("old", state = "cancelled"), action("w"), action("d", what = "delete", releaseAt = release + 1))
        assertEquals("w", runningPhoneAction(list, "words", (release - 10).toULong())?.id)
        assertEquals("w", runningPhoneAction(list, "words", (release + 10).toULong())?.id)
        assertNull(runningPhoneAction(list, "words", expires.toULong()))
        assertNull(runningPhoneAction(list, "leave", release.toULong()))
    }

    /**
     * A double tap: the second start arrives while the first is still waiting for the relay. It
     * waits its turn, finds the first's record and returns it; the relay is asked once.
     */
    @Test
    fun aSecondStartWhileTheFirstIsOnItsWayReturnsTheSameRecord() = runTest {
        val starts = PhoneActionStarts()
        val stored = mutableListOf<DelayedAction>()
        val relayCalls = AtomicInteger()
        val relayAnswer = CompletableDeferred<Unit>()
        suspend fun start() = starts.start(running = { runningPhoneAction(stored, "words", (release - 10).toULong()) }) {
            relayCalls.incrementAndGet()
            relayAnswer.await()
            action("first").also { stored += it }
        }
        val first = async { start() }
        val second = async { start() }
        testScheduler.runCurrent()
        assertEquals(1, relayCalls.get())
        relayAnswer.complete(Unit)
        val a = first.await()
        val b = second.await()
        assertEquals("first", a?.id)
        assertEquals(a, b)
        assertEquals(1, relayCalls.get())
        assertEquals(1, stored.size)
    }

    /** At a trusted place nothing is stored: each start goes ahead at once (null). */
    @Test
    fun startsAtATrustedPlaceGoAheadEachTime() = runTest {
        val starts = PhoneActionStarts()
        var begun = 0
        repeat(2) { assertNull(starts.start(running = { null }) { begun++; null as DelayedAction? }) }
        assertEquals(2, begun)
    }
}
