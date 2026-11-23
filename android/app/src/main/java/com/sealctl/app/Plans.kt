package com.sealctl.app

import com.sealctl.core.app.DelayedAction
import com.sealctl.core.app.PlanApprovalRecord
import kotlin.coroutines.cancellation.CancellationException

/**
 * Which approved plan answers a machine's later key requests (SPEC.md 9.6). A plan stops
 * handing out keys once it, or the delayed record it waits on, is cancelled, however the
 * phone learnt of the cancel (here, the socket, a push or the relay list).
 */
internal object Plans {
    /** Plans of [machine] that may still hand out keys. */
    fun live(plans: List<PlanApprovalRecord>, delayed: List<DelayedAction>, machine: String): List<PlanApprovalRecord> {
        val cancelled = delayed.filter { it.state == "cancelled" }.map { it.id }.toSet()
        return plans.filter { it.machine == machine && it.state != "cancelled" && it.delayId !in cancelled }
    }

    /**
     * The plan a request of [machine] belongs to: the live plan with the request's hash, else
     * the newest live one (decide() then compares the hash itself).
     */
    fun forRequest(plans: List<PlanApprovalRecord>, delayed: List<DelayedAction>, machine: String, hash: String?): PlanApprovalRecord? {
        val live = live(plans, delayed, machine)
        return live.filter { hash != null && it.planHash == hash }.maxByOrNull { it.notBefore }
            ?: live.maxByOrNull { it.notBefore }
    }

    /**
     * A plan that waited on a delay could have been cancelled from a computer without this
     * phone hearing of it yet: the relay is asked before it hands out keys.
     */
    fun needsRelayCheck(plan: PlanApprovalRecord?): Boolean = plan?.delayId != null

    /** The plan after asking the relay: none when the relay did not answer, so the person decides. */
    fun afterRelayCheck(fetched: Boolean, plans: List<PlanApprovalRecord>, delayed: List<DelayedAction>, machine: String, hash: String?): PlanApprovalRecord? =
        if (fetched) forRequest(plans, delayed, machine, hash) else null

    /** Plans still open whose delayed record is cancelled: these must be recorded as cancelled. */
    fun toCancel(plans: List<PlanApprovalRecord>, delayed: List<DelayedAction>): List<PlanApprovalRecord> {
        val cancelled = delayed.filter { it.state == "cancelled" }.map { it.id }.toSet()
        return plans.filter { it.state != "cancelled" && it.delayId != null && it.delayId in cancelled }
    }

    /**
     * What a cancel from this phone records (SPEC.md 11.23): the delayed record [id], cancelled
     * by the phone, and every plan waiting on it.
     */
    fun cancelledHere(delayed: List<DelayedAction>, plans: List<PlanApprovalRecord>, id: String): Pair<DelayedAction?, List<PlanApprovalRecord>> =
        delayed.firstOrNull { it.id == id }?.copy(state = "cancelled", cancelledBy = "phone") to
            plans.filter { it.delayId == id && it.state != "cancelled" }.map { it.copy(state = "cancelled") }

    /**
     * A cancel from this phone: [relayCancel] asks the relay, and [record] writes
     * [cancelledHere]. Returns the relay's error, or null when the relay took the cancel.
     */
    suspend fun cancelFromPhone(relayCancel: suspend () -> Unit, record: () -> Unit): Exception? =
        try {
            relayCancel()
            record()
            null
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            e
        }
}
