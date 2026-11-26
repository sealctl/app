package com.sealctl.app

import com.sealctl.core.app.DelayedAction
import com.sealctl.core.app.PlanApprovalRecord
import com.sealctl.relay.RateLimitedException
import com.sealctl.relay.RelayDelayed
import com.sealctl.relay.RelayException
import kotlin.coroutines.cancellation.CancellationException
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock

/**
 * Which approved plan answers a machine's later key requests (SPEC.md 9.6). A plan stops
 * handing out keys once it, or the delayed record it waits on, is cancelled, however the
 * phone learnt of the cancel (here, the socket, a push or the relay list).
 */
internal object Plans {
    /**
     * A record on the relay's list this install does not know: approved on another install for
     * a machine (`unseal_all`), or a phone-only action another install started, whose record
     * carries no kind ([Texts.OTHER_DEVICE], SPEC.md 11.23).
     */
    fun fromRelay(d: RelayDelayed): DelayedAction =
        DelayedAction(d.id, if (d.machine != null) "unseal_all" else Texts.OTHER_DEVICE, d.machine,
            d.releaseAt.toULong(), d.expires.toULong(), d.state, d.by, d.created.toULong())

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
     * by the phone (unless it is already cancelled), and every plan waiting on it.
     */
    fun cancelledHere(delayed: List<DelayedAction>, plans: List<PlanApprovalRecord>, id: String): Pair<DelayedAction?, List<PlanApprovalRecord>> =
        delayed.firstOrNull { it.id == id && it.state != "cancelled" }?.copy(state = "cancelled", cancelledBy = "phone") to
            plans.filter { it.delayId == id && it.state != "cancelled" }.map { it.copy(state = "cancelled") }

    /**
     * A cancel from this phone: [record] writes [cancelledHere] first, then [relayCancel] asks
     * the relay. The plan hands out no more keys whatever the relay answers: `404 gone` (the
     * machine already fetched the record, or it expired) or no answer at all (fail closed).
     * Returns the relay's error, or null when the relay took the cancel.
     */
    suspend fun cancelFromPhone(relayCancel: suspend () -> Unit, record: () -> Unit): Exception? {
        record()
        return try {
            relayCancel()
            null
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            e
        }
    }

    /** A delayed record's state from which it never waits again (SPEC.md 11.23). */
    fun ended(state: String): Boolean = state == "cancelled" || state == "finished" || state == "gone" || state == "expired"

    /**
     * Whether the relay's list ([relayState]) is written over the stored record [mine] (SPEC.md
     * 11.23): a record that ended stays ended, since the list may have been read before that end;
     * only a cancel, which says who cancelled, replaces "gone" or "expired".
     */
    fun takesRelayState(mine: DelayedAction, relayState: String): Boolean = when {
        mine.state == relayState -> false
        !ended(mine.state) -> true
        else -> relayState == "cancelled" && (mine.state == "gone" || mine.state == "expired")
    }

    /**
     * A record this phone cancelled that the relay's list still shows live ([relayState]
     * `waiting` or `released`): the relay did not get that cancel, so it is sent again.
     */
    fun cancelAgain(mine: DelayedAction, relayState: String): Boolean =
        mine.state == "cancelled" && mine.cancelledBy == "phone" && (relayState == "waiting" || relayState == "released")

    /**
     * Sends the cancel of [id] again ([cancelAgain]) when [resends] says it is due, and keeps
     * what the relay answered.
     */
    suspend fun resendCancel(id: String, resends: CancelResends, send: suspend () -> Unit) {
        if (!resends.due(id)) return
        val error = try {
            send()
            null
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            e
        }
        resends.answered(id, error)
    }
}

/**
 * The cancels this phone sends again from the relay's list, for this run of the app (SPEC.md
 * 11.23; client loops pause after an error and honour `429`). A cancel the relay took, or one
 * that got an answer that will not change (`404 gone`: the record is gone; `403`; any other
 * `4xx`), is not sent again. A `429` waits out its window (`retryAfter`); no answer, a `5xx` or
 * a `401` waits 15 s, twice as long after each further failure, at most 15 minutes.
 */
internal class CancelResends(private val now: () -> Long = System::currentTimeMillis) {
    private val done = HashSet<String>()
    /** Per id: when the next try may go out, and the failures so far. */
    private val waits = HashMap<String, Pair<Long, Int>>()

    @Synchronized
    fun due(id: String): Boolean = id !in done && now() >= (waits[id]?.first ?: 0L)

    @Synchronized
    fun answered(id: String, error: Exception?) {
        val failures = waits[id]?.second ?: 0
        when {
            error == null || isFinal(error) -> {
                done += id
                waits -= id
            }
            error is RateLimitedException -> waits[id] = maxOf(error.until, now()) to failures
            else -> waits[id] = now() + backoffMs(failures + 1) to failures + 1
        }
    }

    companion object {
        /** An answer the same call would get again. */
        fun isFinal(e: Exception): Boolean =
            e is RelayException && e.status in 400..499 && e.status != 401 && e.status != 408 && e.status != 429

        /** The wait after [failures] tries with no usable answer: 15 s doubling, at most 15 minutes. */
        fun backoffMs(failures: Int): Long = minOf(15_000L shl (failures - 1).coerceIn(0, 6), 15 * 60_000L)
    }
}

/**
 * Delayed ids this install is registering with the relay (SPEC.md 11.23). The relay's list can
 * show one before its answer reaches the app; it is this install's, not another's. The start's
 * write and a refresh's check take the same lock, and the refresh looks for a stored record
 * again under it, so a refresh that found none before the start stored its own never writes
 * it back as another install's.
 */
internal class StartingDelayed {
    private val ids = HashSet<String>()

    /** Holds [id] while [add] registers it with the relay, then [record]s what the relay answered. */
    suspend fun <T, R> start(id: String, add: suspend () -> T, record: (T) -> R): R {
        synchronized(this) { ids += id }
        try {
            val answer = add()
            return synchronized(this) { record(answer) }
        } finally {
            synchronized(this) { ids -= id }
        }
    }

    /**
     * [put]s a record on the relay's list as another install's ([Plans.fromRelay]), unless it is
     * being started here or [stored] finds it stored meanwhile.
     */
    fun fromRelay(d: RelayDelayed, stored: (String) -> Boolean, put: (DelayedAction) -> Unit) {
        synchronized(this) { if (d.id !in ids && !stored(d.id)) put(Plans.fromRelay(d)) }
    }
}

/**
 * Starts of the actions on the phone (SPEC.md 11.23), one at a time per kind ([what]): a start
 * first looks for one of its kind still waiting or ready ([running]) and returns that instead
 * of calling [begin], so a double tap, or a second screen starting the same kind while the
 * first start is still on its way to the relay, never registers a second two-hour delay. Each
 * kind has its own lock: a slow start of Show words does not hold back a Delete. A start waits
 * at most as long as the relay call in [begin], which the relay client bounds (`callTimeout`).
 */
internal class PhoneActionStarts {
    private val locks = HashMap<String, Mutex>()

    private fun lock(what: String): Mutex = synchronized(locks) { locks.getOrPut(what) { Mutex() } }

    suspend fun <T : Any> start(what: String, running: () -> T?, begin: suspend () -> T?): T? =
        lock(what).withLock { running() ?: begin() }
}

/**
 * Confirmations of the places this install announced (SPEC.md 11.9): `finish` is sent for a
 * place record only while it is still waiting or released here, and one at a time per record,
 * so a refresh that overlaps another (the alarm and the app), or one whose list was read before
 * the confirmation, never asks the relay again after its final answer.
 */
internal class PlaceConfirms {
    private val running = HashSet<String>()

    /** Whether [d] still needs `finish`: a place record that has not ended. */
    fun due(d: DelayedAction?): Boolean = d != null && d.what == Texts.PLACE && (d.state == "waiting" || d.state == "released")

    /**
     * Runs [confirm] for [id] when the record [stored] reads is [due] and no confirmation of it
     * runs already. Returns whether it ran.
     */
    suspend fun confirm(id: String, stored: () -> DelayedAction?, confirm: suspend () -> Unit): Boolean {
        if (!due(stored())) return false
        synchronized(running) { if (!running.add(id)) return false }
        try {
            // Read again under the claim: one that just ended is not asked about again.
            if (!due(stored())) return false
            confirm()
            return true
        } finally {
            synchronized(running) { running.remove(id) }
        }
    }
}
