package com.sealctl.app

import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicReference
import kotlin.concurrent.thread
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** The timing rules of an answer (SPEC.md 8.3, 8.5). */
class AnswersTest {
    @Test
    fun deadlineOnThePhonesClock() {
        // Clocks agree: the relay's `expires`, plus the delivery time.
        assertEquals(70_100L, Answers.deadline(seenAt = 10_000, created = 9_900, expires = 70_000))
        // Phone 2 minutes ahead of the relay: seen "after" it expired by the relay's clock; the
        // request still gets its minute on this phone.
        assertEquals(260_000L, Answers.deadline(seenAt = 200_000, created = 80_000, expires = 140_000))
        // Phone behind the relay: the relay's `expires`, which the relay enforces anyway.
        assertEquals(110_000L, Answers.deadline(seenAt = 10_000, created = 50_000, expires = 110_000))
        // Never more than the relay's clock window past `expires`.
        assertEquals(360_000L, Answers.deadline(seenAt = 10_000_000, created = 0, expires = 60_000))
    }

    @Test
    fun oneAnswerPerRequestAtATime() {
        val f = InFlight()
        assertEquals("card", f.claim("r1") { "card" })
        // The card button while the notification action's answer is on its way.
        assertNull(f.claim("r1") { "card" })
        assertTrue("r1" in f)
        assertEquals("card", f.claim("r2") { "card" })
        // A card that is gone is not claimed.
        assertNull(f.claim("r3") { null })
        assertFalse("r3" in f)
        // The timer leaves a card with an answer on its way.
        assertNull(f.unlessAnswering("r1") { "expired" })
        f.done("r1")
        assertFalse("r1" in f)
        assertEquals("expired", f.unlessAnswering("r1") { "expired" })
        // A reply that did not go: the next tap answers.
        assertEquals("card", f.claim("r1") { "card" })
    }

    /** The timer on another thread while an answer claims the card: it waits, then leaves the card. */
    @Test
    fun theTimerWaitsForAClaimInProgress() {
        val f = InFlight()
        val expired = AtomicBoolean(false)
        lateinit var timer: Thread
        val claimed = f.claim("r1") {
            timer = thread { f.unlessAnswering("r1") { expired.set(true); "expired" } }
            timer.join(300)
            // Held off while the answer checks the card and its time.
            assertTrue(timer.isAlive)
            "card"
        }
        timer.join()
        assertEquals("card", claimed)
        assertFalse(expired.get())
    }

    /** A tap on another thread while the timer expires the card: it waits, then finds it expired. */
    @Test
    fun aTapWaitsForAnExpiryInProgress() {
        val f = InFlight()
        val cardExpired = AtomicBoolean(false)
        val claimed = AtomicReference<String?>("unset")
        lateinit var tap: Thread
        f.unlessAnswering("r1") {
            tap = thread { claimed.set(f.claim("r1") { if (cardExpired.get()) null else "card" }) }
            tap.join(300)
            assertTrue(tap.isAlive)
            cardExpired.set(true)
            "expired"
        }
        tap.join()
        assertNull(claimed.get())
    }

    @Test
    fun aStopBeforeTheForegroundWorkWins() {
        val l = Lifecycle()
        val turn = l.started()
        assertTrue(l.current(turn))
        // onStop runs before the coroutine started by onStart reaches onForeground.
        l.stopped()
        assertFalse(l.current(turn))
        assertFalse(l.foreground)
        // A later start does not revive the earlier turn.
        val next = l.started()
        assertFalse(l.current(turn))
        assertTrue(l.current(next))

        val sockets = sockets()
        val t = sockets.started()
        sockets.stopped()
        assertFalse(sockets.open(t))
        assertFalse(sockets.isOpen)
    }

    /**
     * Erase (from Settings, or Leave's Done) with the app on screen closes the socket; onboarding
     * again in the same foreground opens it.
     */
    @Test
    fun afterEraseOnboardingOpensTheSocket() {
        var created = 0
        val sockets = sockets { created++ }
        val t = sockets.started()
        assertTrue(sockets.open(t))
        assertTrue(sockets.isOpen)
        sockets.close()
        assertFalse(sockets.isOpen)
        // Onboarding.finish: onForeground() with the turn of now.
        assertTrue(sockets.open(sockets.now()))
        assertTrue(sockets.isOpen)
        assertEquals(2, created)
    }

    private fun sockets(onCreate: () -> Unit = {}) =
        ForegroundSocket(create = { onCreate(); Any() }, start = {}, stop = {})
}
