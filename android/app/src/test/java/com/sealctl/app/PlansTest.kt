package com.sealctl.app

import com.sealctl.core.app.DelayedAction
import com.sealctl.core.app.PlanApprovalRecord
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test
import com.sealctl.relay.RateLimitedException
import com.sealctl.relay.RelayDelayed
import com.sealctl.relay.RelayException
import java.io.IOException
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.async
import kotlinx.coroutines.test.runTest
import kotlinx.serialization.json.JsonObject

/** The plan that answers later key requests (SPEC.md 9.6, 11.23). */
class PlansTest {
    private fun plan(hash: String, notBefore: Long, state: String = "approved", delayId: String? = null, machine: String = "m") =
        PlanApprovalRecord(machine, "req-$hash", hash, emptyList(), emptyList(), notBefore.toULong(), state, delayId, true)

    private fun delayed(id: String, state: String) =
        DelayedAction(id, "unseal_all", "m", 0u, 0u, state, null)

    @Test
    fun aCancelledDelayClosesItsPlan() {
        // The plan record still says "delayed": the cancel came by push or the relay list.
        val plans = listOf(plan("h", 1000, state = "delayed", delayId = "d1"))
        val list = listOf(delayed("d1", "cancelled"))
        assertNull(Plans.forRequest(plans, list, "m", "h"))
        assertEquals(listOf("h"), Plans.toCancel(plans, list).map { it.planHash })
        assertEquals("h", Plans.forRequest(plans, listOf(delayed("d1", "waiting")), "m", "h")?.planHash)
        assertTrue(Plans.toCancel(plans, listOf(delayed("d1", "waiting"))).isEmpty())
    }

    @Test
    fun theRequestsHashWinsOverANewerPlan() {
        // B is newer but cancelled; A was approved later at a trusted place with an earlier start.
        val plans = listOf(
            plan("a", 1000),
            plan("b", 9000, state = "cancelled", delayId = "d1"),
            plan("c", 5000),
            plan("a", 9999, machine = "other"),
        )
        assertEquals("a", Plans.forRequest(plans, emptyList(), "m", "a")?.planHash)
        assertEquals(1000uL, Plans.forRequest(plans, emptyList(), "m", "a")?.notBefore)
        assertEquals("c", Plans.forRequest(plans, emptyList(), "m", "x")?.planHash)
        assertEquals("c", Plans.forRequest(plans, emptyList(), "m", null)?.planHash)
        assertNull(Plans.forRequest(plans, emptyList(), "nobody", "a"))
    }

    @Test
    fun aDelayedPlanAsksTheRelayFirst() {
        val delayedPlan = plan("h", 1000, state = "delayed", delayId = "d1")
        assertTrue(Plans.needsRelayCheck(delayedPlan))
        assertFalse(Plans.needsRelayCheck(plan("h", 1000)))
        assertFalse(Plans.needsRelayCheck(null))
        val plans = listOf(delayedPlan)
        // The relay's list says a computer cancelled it: no plan.
        assertNull(Plans.afterRelayCheck(true, plans, listOf(delayed("d1", "cancelled")), "m", "h"))
        // Still released and not cancelled: the plan answers.
        assertEquals("h", Plans.afterRelayCheck(true, plans, listOf(delayed("d1", "released")), "m", "h")?.planHash)
        // The relay did not answer: no plan, the person decides.
        assertNull(Plans.afterRelayCheck(false, plans, listOf(delayed("d1", "released")), "m", "h"))
    }

    @Test
    fun aCancelHereRecordsThePlanAndItsDelay() {
        val plans = listOf(plan("h", 1000, state = "delayed", delayId = "d1"), plan("x", 500))
        val (d, cancelled) = Plans.cancelledHere(listOf(delayed("d1", "waiting")), plans, "d1")
        assertEquals("cancelled", d?.state)
        assertEquals("phone", d?.cancelledBy)
        assertEquals(listOf("h" to "cancelled"), cancelled.map { it.planHash to it.state })
        // Recorded: the plan hands out no more keys; the other plan is untouched.
        assertNull(Plans.forRequest(cancelled, listOf(d!!), "m", "h"))
        assertEquals("x", Plans.forRequest(plans.drop(1), listOf(d), "m", "h")?.planHash)
        // Already cancelled from a computer: that record stays as it is.
        val byComputer = delayed("d1", "cancelled").copy(cancelledBy = "m1")
        assertNull(Plans.cancelledHere(listOf(byComputer), plans, "d1").first)
    }

    @Test
    fun aCancelHereClosesThePlanWhateverTheRelayAnswers() = runTest {
        // The relay took it; `404 gone` (the machine fetched the record, or it expired); no answer.
        val gone = IllegalStateException("404 gone")
        val offline = IOException("no route to host")
        for (answer in listOf<Exception?>(null, gone, offline)) {
            var recorded = false
            val failed = Plans.cancelFromPhone(relayCancel = { if (answer != null) throw answer }) { recorded = true }
            assertTrue("recorded after ${answer?.message ?: "200"}", recorded)
            assertSame(answer, failed)
        }
    }

    @Test
    fun aCancelTheRelayDidNotGetIsSentAgain() {
        val mine = delayed("d1", "cancelled").copy(cancelledBy = "phone")
        assertTrue(Plans.cancelAgain(mine, "waiting"))
        assertTrue(Plans.cancelAgain(mine, "released"))
        assertFalse(Plans.cancelAgain(mine, "cancelled"))
        // Cancelled from a computer, or not cancelled here: nothing to send.
        assertFalse(Plans.cancelAgain(mine.copy(cancelledBy = "m1"), "waiting"))
        assertFalse(Plans.cancelAgain(delayed("d1", "waiting"), "waiting"))
    }

    @Test
    fun aResentCancelThatGotAFinalAnswerIsNotSentAgain() = runTest {
        var now = 1_000_000L
        val resends = CancelResends { now }
        // `404 gone` (the record is gone), `403`, `400`, and a cancel the relay took.
        val answers = listOf<Exception?>(RelayException(404, "gone"), RelayException(403, "forbidden"), RelayException(400, "bad_id"), null)
        for ((i, answer) in answers.withIndex()) {
            val id = "d$i"
            var sent = 0
            Plans.resendCancel(id, resends) { sent++; if (answer != null) throw answer }
            // The countdown asks the relay's list every 15 s; an hour of that sends nothing more.
            repeat(240) { now += 15_000; Plans.resendCancel(id, resends) { sent++ } }
            assertEquals("after ${answer?.message ?: "200"}", 1, sent)
        }
    }

    @Test
    fun aResentCancelWaitsOutARateLimitAndBacksOffWithoutAnAnswer() = runTest {
        var now = 1_000_000L
        val resends = CancelResends { now }
        var sent = 0
        // `429`: nothing until its window ends (Retry-After).
        Plans.resendCancel("d1", resends) { sent++; throw RateLimitedException(now + 120_000, null, JsonObject(emptyMap())) }
        now += 119_000
        Plans.resendCancel("d1", resends) { sent++ }
        assertEquals(1, sent)
        // No answer: 15 s, then twice as long each time.
        now += 1_000
        Plans.resendCancel("d1", resends) { sent++; throw IOException("offline") }
        assertEquals(2, sent)
        now += 14_000
        Plans.resendCancel("d1", resends) { sent++ }
        assertEquals(2, sent)
        now += 1_000
        Plans.resendCancel("d1", resends) { sent++; throw RelayException(503, "http_503") }
        assertEquals(3, sent)
        now += 29_000
        Plans.resendCancel("d1", resends) { sent++ }
        assertEquals(3, sent)
        now += 1_000
        Plans.resendCancel("d1", resends) { sent++ }
        assertEquals(4, sent)
        // Taken: done.
        now += 3_600_000
        Plans.resendCancel("d1", resends) { sent++ }
        assertEquals(4, sent)
        assertEquals(15 * 60_000L, CancelResends.backoffMs(20))
    }

    @Test
    fun aPhoneOnlyRecordFromAnotherInstallIsNamedAsSuch() {
        // Another install with the same words started showing the words: the relay's record
        // has no machine and no kind (SPEC.md 11.23).
        val other = Plans.fromRelay(RelayDelayed("d1", null, 1_000, 7_201_000, 8_101_000, "waiting"))
        assertEquals(Texts.OTHER_DEVICE, other.what)
        assertNull(other.machine)
        assertEquals("Started on another of your devices", Texts.delayScreenTitle(other.what, null))
        assertEquals(Texts.otherDeviceBody(7_201_000), Texts.delayWaiting(other.what, 7_201_000))
        assertEquals("A protected action started on another of your devices", Texts.delayedNote(other.what, 7_201_000).first)
        assertTrue(Texts.delayedAt(other.what, "This phone", 7_201_000).startsWith("A protected action started on another of your devices"))

        // Another install approved `unseal --all` for a machine: still that machine's leaving.
        val machine = Plans.fromRelay(RelayDelayed("d2", "m1", 1_000, 7_201_000, 8_101_000, "waiting"))
        assertEquals("unseal_all", machine.what)
        assertEquals("Leaving sealctl on dev@mbp.example.com", Texts.delayScreenTitle(machine.what, "dev@mbp.example.com"))
        assertEquals("Leaving sealctl on this computer", Texts.delayScreenTitle(machine.what, null))
        assertEquals(Texts.DELAY_BODY, Texts.delayWaiting(machine.what, 7_201_000))
        assertEquals(Texts.DELAYED_TITLE to Texts.DELAYED_BODY, Texts.delayedNote(machine.what, 7_201_000))
        assertEquals(Texts.handsBackAt("dev@mbp.example.com", 7_201_000), Texts.delayedAt(machine.what, "dev@mbp.example.com", 7_201_000))
    }

    /** This install's records, written the way `PutDelayed` writes them: by id, replacing. */
    private class Records {
        val list = mutableListOf<DelayedAction>()
        fun put(d: DelayedAction) { list.removeAll { it.id == d.id }; list += d }
        fun stored(id: String) = list.any { it.id == id }
    }

    private val onRelay = RelayDelayed("d1", null, 1_000, 7_201_000, 10_801_000, "waiting")

    private fun words(d: RelayDelayed) =
        DelayedAction(d.id, "words", null, d.releaseAt.toULong(), d.expires.toULong(), "waiting", null)

    @Test
    fun aDelayThisInstallIsStartingIsNotAnotherDevices() = runTest {
        // The relay has the record; its answer has not reached this install (SPEC.md 11.23).
        val starting = StartingDelayed()
        val records = Records()
        val held = CompletableDeferred<Unit>()
        val answer = CompletableDeferred<RelayDelayed>()
        val start = async {
            starting.start("d1", add = { held.complete(Unit); answer.await() }) { d -> words(d).also(records::put) }
        }
        held.await()
        // A push, the socket or a screen refreshes the relay's list now.
        starting.fromRelay(onRelay, records::stored, records::put)
        assertEquals(emptyList<String>(), records.list.map { it.what })
        answer.complete(onRelay)
        start.await()
        assertEquals(listOf("words"), records.list.map { it.what })
    }

    @Test
    fun aRefreshThatFoundNoRecordBeforeTheStartStoredItKeepsIt() = runTest {
        // The refresh read this install's records (none for d1), then the start stored "words"
        // and finished, then the refresh writes what it found on the relay's list.
        val starting = StartingDelayed()
        val records = Records()
        starting.start("d1", add = { onRelay }) { d -> words(d).also(records::put) }
        starting.fromRelay(onRelay, records::stored, records::put)
        assertEquals(listOf("words"), records.list.map { it.what })
    }

    @Test
    fun aRecordNoInstallHereIsStartingIsAnotherDevices() = runTest {
        val starting = StartingDelayed()
        val records = Records()
        // A start that failed holds its id no longer.
        runCatching { starting.start("d1", add = { throw IOException("offline") }) { d: RelayDelayed -> words(d) } }
        starting.fromRelay(onRelay, records::stored, records::put)
        assertEquals(listOf(Texts.OTHER_DEVICE), records.list.map { it.what })
    }
}
