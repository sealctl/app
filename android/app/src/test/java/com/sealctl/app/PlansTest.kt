package com.sealctl.app

import com.sealctl.core.app.DelayedAction
import com.sealctl.core.app.PlanApprovalRecord
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

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
}
