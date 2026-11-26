package com.sealctl.app

import com.sealctl.core.app.GrantRecord
import com.sealctl.core.app.LocationSample
import com.sealctl.core.app.Machine
import com.sealctl.core.app.TrustedPlace
import com.sealctl.core.app.placesLeftByFix
import com.sealctl.places.Fix
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicLong

/**
 * Leaving trusted places (SPEC.md 11.9), apart from the system's geofences. A machine's
 * allowance comes from its latest `open` allowed for a session; when that was at a trusted
 * place, the phone no longer being inside the place locks the machine, wherever its day began.
 * The phone learns that from an exit (also the geofences' initial exit for a place it is
 * outside when they are registered), from a fresh fix outside the place, or from location no
 * longer watching the edges at all.
 *
 * [grantsLeft] gives the allowances to lock for a list of places (the shared core's rule);
 * [lock] sends one lock and says whether the relay took it; [onLocked] records that it did.
 */
class PlaceExits(
    private val grantsLeft: (List<String>) -> List<GrantRecord>,
    private val places: () -> List<TrustedPlace>,
    private val machine: (String) -> Machine?,
    private val lock: suspend (Machine) -> Boolean,
    private val onLocked: (GrantRecord) -> Unit,
) {
    /**
     * Exits from each place so far, to tell whether the phone left the place an answer was
     * decided at while that answer was on its way. Counted by place: an initial exit for a place
     * the phone is not near says nothing about the one it is at.
     */
    private val exits = ConcurrentHashMap<String, Int>()

    /** When a fix was last taken to check for a missed exit, System ms. */
    private val lastFix = AtomicLong(0)

    fun exitsFrom(place: String?): Int = place?.let { exits[it] } ?: 0

    /**
     * The phone is not inside these places: counts an exit from each, then locks every machine
     * allowed at one of them. The allowances locked, with their machines.
     */
    suspend fun left(ids: List<String>): List<Pair<GrantRecord, Machine>> {
        for (id in ids) exits.merge(id, 1) { a, b -> a + b }
        return lockAll(grantsLeft(ids))
    }

    /**
     * An answer decided at [place] was posted after the phone left it: the allowances from
     * there, this one among them, are locked now that it is recorded. Whether [machine] had one
     * there (locked now or not): without one ("Allow once") the caller locks it itself; with one
     * whose lock did not go, the next exit, fix or start sends it again.
     */
    suspend fun lockAt(place: String, machine: String): Boolean {
        val grants = grantsLeft(listOf(place))
        lockAll(grants)
        return grants.any { it.machine == machine }
    }

    /**
     * The phone can no longer notice leaving a place (location "Allow all the time" taken away,
     * location turned off, the geofences not registered): every machine allowed at a trusted
     * place is locked. Not an exit: no place is counted as left.
     */
    suspend fun unwatched(): List<Pair<GrantRecord, Machine>> = lockAll(grantsLeft(liveIds()))

    /** The trusted places [fix] shows the phone is outside, at [now] (System ms). */
    fun leftByFix(fix: Fix, now: Long): List<String> =
        placesLeftByFix(places(), LocationSample(fix.lat, fix.lon, fix.accuracy, fix.time.toULong()), now.toULong())

    /**
     * Whether to take a fix now to check for a missed exit: only while a place counts as
     * [current] or a machine's allowance came from one, and at most once per [minGapMs]. Claims
     * the slot when it says yes; [noFix] gives it back when no fix came.
     */
    fun fixDue(current: String?, now: Long, minGapMs: Long): Boolean {
        if (current == null && grantsLeft(liveIds()).isEmpty()) return false
        val last = lastFix.get()
        if (now - last in 0 until minGapMs) return false
        return lastFix.compareAndSet(last, now)
    }

    /** The fix claimed at [claimedAt] did not come: the next check may try again at once. */
    fun noFix(claimedAt: Long) {
        lastFix.compareAndSet(claimedAt, 0)
    }

    private fun liveIds(): List<String> = places().filter { !it.deleted }.map { it.id }

    /** A lock that did not go stays unlocked, so the next exit, fix or start sends it again. */
    private suspend fun lockAll(grants: List<GrantRecord>): List<Pair<GrantRecord, Machine>> = grants.mapNotNull { g ->
        val m = machine(g.machine) ?: return@mapNotNull null
        if (!lock(m)) return@mapNotNull null
        onLocked(g)
        g to m
    }
}
