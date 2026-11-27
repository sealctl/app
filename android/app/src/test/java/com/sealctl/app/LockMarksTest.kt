package com.sealctl.app

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** The card after a lock (SPEC.md 11.8): "Locking…" until a status answers it. */
class LockMarksTest {
    private val at = 1_795_266_000_000L

    @Test
    fun anOpenStatusMadeBeforeTheLockDoesNotEndIt() {
        val marks = LockMarks.sent(emptyMap(), "m", at, accepted = at)
        assertEquals(marks, LockMarks.status(marks, "m", at - 30_000, open = true))
        // A session opened after the lock: Open again.
        assertTrue(LockMarks.status(marks, "m", at + 1_000, open = true).isEmpty())
        // Locked, whenever made: the lock is confirmed.
        assertTrue(LockMarks.status(marks, "m", at - 30_000, open = false).isEmpty())
        // Another machine's status changes nothing.
        assertEquals(marks, LockMarks.status(marks, "x", at + 1_000, open = false))
    }

    @Test
    fun lockedOnceTheRelayHeldItAMinuteWithNoStatus() {
        val queued = LockMarks.sent(emptyMap(), "m", at, accepted = 0)
        // Still in the outbox: never settled, however long.
        assertFalse(LockMarks.settled(queued.getValue("m"), at + 3_600_000))
        val taken = LockMarks.accepted(queued, "m", at + 120_000)
        assertFalse(LockMarks.settled(taken.getValue("m"), at + 120_000 + 59_999))
        assertTrue(LockMarks.settled(taken.getValue("m"), at + 120_000 + LockMarks.SETTLE_MS))
        // Taken once: a later delivery does not move it.
        assertEquals(taken, LockMarks.accepted(taken, "m", at + 999_999))
    }

    @Test
    fun prunedAndKept() {
        val marks = LockMarks.sent(LockMarks.sent(emptyMap(), "m", at, 0), "gone", at, at)
        assertEquals(setOf("m"), LockMarks.pruned(marks, at + 1_000) { it == "m" }.keys)
        assertTrue(LockMarks.pruned(marks, at + LockMarks.MAX_AGE_MS) { true }.isEmpty())
        assertEquals(marks, LockMarks.decode(LockMarks.encode(marks)))
        assertTrue(LockMarks.decode("not json").isEmpty())
    }
}
