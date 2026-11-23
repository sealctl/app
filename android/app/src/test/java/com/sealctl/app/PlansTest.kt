package com.sealctl.app

import com.sealctl.core.app.DelayedAction
import com.sealctl.core.app.PlanApprovalRecord
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.IOException
import kotlinx.coroutines.test.runTest

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
}
