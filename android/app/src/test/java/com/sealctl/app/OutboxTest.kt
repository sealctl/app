package com.sealctl.app

import com.sealctl.core.app.GrantRecord
import com.sealctl.relay.RateLimitedException
import com.sealctl.relay.RelayException
import com.sealctl.relay.UnavailableException
import java.io.File
import java.io.IOException
import java.nio.file.Files
import kotlinx.coroutines.test.runTest
import kotlinx.serialization.json.JsonObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/** The outbox of locks and notices (SPEC.md 8.1, 9.6, 11.9), with a scripted relay and clock. */
class OutboxTest {
    private var clock = 1_795_266_000_000L
    private val sent = mutableListOf<String>()
    private val delivered = mutableListOf<String>()
    private val wakes = mutableListOf<Long>()
    private var live = setOf("m1", "m2")
    /** What the relay answers next; null: it takes the message. */
    private val answers = ArrayDeque<Exception?>()
    private val dir: File = Files.createTempDirectory("outbox").toFile()

    private fun outbox(file: File? = File(dir, "outbox.json")) = Outbox(
        file = file,
        now = { clock },
        post = { o, _ -> answers.removeFirstOrNull()?.let { throw it }; sent += o.id },
        live = { it in live },
        delivered = { delivered += it.id },
        wake = { wakes += it },
        clock = { clock },
        random = { 0.5 },
    )

    private fun lock(id: String, machine: String = "m1", grant: GrantRecord? = null) = Outgoing(id, machine, "sealed-$id", true, clock, grant)
    private fun notice(id: String, machine: String = "m1") = Outgoing(id, machine, "sealed-$id", false, clock)
    private fun maintenance(secs: Long) = UnavailableException(clock + secs * 1000, 503, "maintenance", JsonObject(emptyMap()))

    @Test
    fun aMessageTheRelayTakesIsNotKept() = runTest {
        val box = outbox()
        assertEquals(Outbox.Result.SENT, box.send(lock("a"), userTapped = false))
        assertEquals(listOf("a"), sent)
        assertTrue(box.pending().isEmpty())
    }

    @Test
    fun maintenanceKeepsItUntilRetryAfter() = runTest {
        val box = outbox()
        answers += maintenance(120)
        assertEquals(Outbox.Result.QUEUED, box.send(lock("a"), userTapped = false))
        assertEquals(listOf(120_000L), wakes)
        // Too early: nothing is sent, and it asks to be woken when the wait is over.
        clock += 60_000
        box.flush()
        assertTrue(sent.isEmpty())
        assertEquals(60_000L, wakes.last())
        // What the app sends by itself meanwhile waits too, without a call.
        assertEquals(Outbox.Result.QUEUED, box.send(notice("n"), userTapped = false))
        assertTrue(sent.isEmpty())
        clock += 60_000
        box.flush()
        assertEquals(listOf("a", "n"), sent)
        assertEquals(listOf("a", "n"), delivered)
        assertTrue(box.pending().isEmpty())
    }

    @Test
    fun noAnswerBacksOffDoubling() = runTest {
        val box = outbox()
        answers += IOException("offline")
        box.send(notice("n"), userTapped = false)
        assertEquals(10_000L, wakes.last())
        clock += 10_000
        answers += RelayException(502, "http_502")
        box.flush()
        assertEquals(20_000L, wakes.last())
        clock += 20_000
        answers += RateLimitedException(clock + 600_000, "phone", JsonObject(emptyMap()))
        box.flush()
        // The rate-limit window, not the backoff.
        assertEquals(600_000L, wakes.last())
        clock += 600_000
        box.flush()
        assertEquals(listOf("n"), sent)
    }

    @Test
    fun aTappedLockGoesAtOnceDuringTheWait() = runTest {
        val box = outbox()
        answers += maintenance(120)
        box.send(lock("a"), userTapped = false)
        // The relay is back early; the person taps Lock now.
        assertEquals(Outbox.Result.SENT, box.send(lock("b"), userTapped = true))
        // The later lock covers the queued one, which counts as delivered (its allowance too).
        assertEquals(listOf("b"), sent)
        assertEquals(listOf("a"), delivered)
        assertTrue(box.pending().isEmpty())
    }

    @Test
    fun aNoticeWaitsBehindTheMachinesQueueALockDoesNot() = runTest {
        val box = outbox()
        answers += IOException("offline")
        box.send(notice("n1"), userTapped = false)
        clock += 10_000
        // The relay is back: a lock for the same machine goes at once and the queue follows.
        assertEquals(Outbox.Result.SENT, box.send(lock("l"), userTapped = false))
        assertEquals(0L, wakes.last())
        // A notice for that machine goes behind the queued one, in order.
        assertEquals(Outbox.Result.QUEUED, box.send(notice("n2"), userTapped = false))
        box.flush()
        assertEquals(listOf("l", "n1", "n2"), sent)
        // Another machine's notice does not wait.
        assertEquals(Outbox.Result.SENT, box.send(notice("n3", "m2"), userTapped = false))
    }

    @Test
    fun oneLockPerMachineKeepingItsAllowance() = runTest {
        val box = outbox()
        val g = GrantRecord("m1", "p1", 5u, 9u, false)
        answers += IOException("offline")
        box.send(lock("a", grant = g), userTapped = false)
        box.send(lock("b"), userTapped = false)
        assertEquals(listOf("b"), box.pending().map { it.id })
        assertEquals(g, box.pending().single().grant)
    }

    @Test
    fun finalAnswersAndObsoleteMessagesAreDropped() = runTest {
        val box = outbox()
        answers += RelayException(404, "not_paired")
        assertEquals(Outbox.Result.REFUSED, box.send(lock("a"), userTapped = false))
        assertTrue(box.pending().isEmpty())
        answers += IOException("offline")
        box.send(notice("n1"), userTapped = false)
        answers += IOException("offline")
        box.send(notice("n2", "m2"), userTapped = false)
        // Unpaired since, and a day old: neither matters any more.
        live = setOf("m2")
        clock += Outbox.MAX_AGE_MS + 1
        box.flush()
        assertTrue(sent.isEmpty())
        assertTrue(box.pending().isEmpty())
        // A 401 (the clock) and a 408 are tried again.
        assertTrue(!Outbox.isFinal(RelayException(401, "clock_skew")))
        assertTrue(!Outbox.isFinal(RelayException(408, "http_408")))
        assertTrue(Outbox.isFinal(RelayException(403, "forbidden")))
    }

    @Test
    fun keptAcrossARestart() = runTest {
        val g = GrantRecord("m1", "p1", 5u, 9u, false)
        answers += maintenance(30)
        outbox().send(lock("a", grant = g), userTapped = false)
        val again = outbox()
        assertEquals(listOf(lock("a", grant = g)), again.pending())
        // A new process tries at once.
        again.flush()
        assertEquals(listOf("a"), sent)
        assertTrue(outbox().pending().isEmpty())
    }
}
