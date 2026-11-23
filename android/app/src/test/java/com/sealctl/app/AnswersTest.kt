package com.sealctl.app

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
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
        assertTrue(f.start("r1"))
        // The card button while the notification action's answer is on its way.
        assertFalse(f.start("r1"))
        assertTrue("r1" in f)
        assertTrue(f.start("r2"))
        f.done("r1")
        assertFalse("r1" in f)
        // A reply that did not go: the next tap answers.
        assertTrue(f.start("r1"))
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
    }
}
