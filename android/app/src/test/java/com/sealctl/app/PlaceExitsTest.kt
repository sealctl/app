package com.sealctl.app

import com.sealctl.core.app.DayRecord
import com.sealctl.core.app.DeviceInfo
import com.sealctl.core.app.GrantRecord
import com.sealctl.core.app.LocalState
import com.sealctl.core.app.Machine
import com.sealctl.core.app.TrustedPlace
import com.sealctl.core.app.grantsToLock
import com.sealctl.places.Fix
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Leaving a trusted place locks the machines allowed there (SPEC.md 11.9), through the shared
 * core's rule (host build, JNA). The owner's Mac: its day began at 07:13 with no place, it was
 * allowed again at Home after "Trust where I am now", and leaving Home did not lock it, because
 * the exit looked only at days begun there.
 */
class PlaceExitsTest {
    private val now = System.currentTimeMillis()
    private val home = TrustedPlace("home", "Home", 50.45, 30.52, 150.0, 1u, 0u, false, true)
    private val desk = TrustedPlace("desk", "Desk", 50.40, 30.60, 150.0, 1u, 0u, false, false)
    private var places = listOf(home, desk)

    private fun machine(key: String) = Machine(
        key = key, boxKey = "box", name = "dev@$key.example.com", os = "macOS 26", model = null, hint = null,
        pairedAt = 0u, nickname = null, lastSeen = null, lastStatus = null, tagShown = false, flagged = false,
        relay = "", updated = 0u, deleted = false,
    )

    private val machines = listOf("mac", "pc", "laptop").associateWith { machine(it) }

    private fun grant(machine: String, place: String?, at: Long = now - 3_600_000) =
        GrantRecord(machine, place, at.toULong(), (now + 8 * 3_600_000).toULong(), false)

    /** The records on this phone: what the store keeps. */
    private var grants = mutableListOf<GrantRecord>()
    private var days = listOf<DayRecord>()
    private val sent = mutableListOf<String>()
    private var relayUp = true

    private fun local() = LocalState(
        days, emptyList(), emptyList(), emptyList(), emptyList(), emptyList(),
        DeviceInfo("", null, "fcm", false, 0u), 0u, 0u, 0u, 0u, false, false, emptyList(), false, 0u, emptyList(), grants.toList(),
    )

    private val exits = PlaceExits(
        grantsLeft = { ids -> grantsToLock(local(), places, ids, now.toULong(), 0) },
        places = { places },
        machine = { machines[it] },
        lock = { m -> if (relayUp) { sent += m.key; true } else false },
        onLocked = { g -> grants.replaceAll { if (it.machine == g.machine && it.at == g.at) it.copy(locked = true) else it } },
    )

    private fun ownersMorning() {
        // Days: the Mac's and the laptop's began with no place, the PC's at Home.
        days = listOf(
            DayRecord("mac", (now - 4 * 3_600_000).toULong(), null, (now + 8 * 3_600_000).toULong()),
            DayRecord("pc", (now - 4 * 3_600_000).toULong(), "home", (now + 8 * 3_600_000).toULong()),
        )
        // Latest sessions: the Mac at Home, the PC at the desk since, the laptop with no place.
        grants = mutableListOf(grant("mac", "home"), grant("pc", "desk"), grant("laptop", null))
    }

    @Test
    fun anExitLocksTheMachinesAllowedThereWhereverTheirDayBegan() = runTest {
        ownersMorning()
        val locked = exits.left(listOf("home"))
        assertEquals(listOf("mac"), locked.map { it.second.key })
        assertEquals(listOf("mac"), sent)
        // Several machines allowed at Home are all locked.
        grants.add(grant("laptop", "home", now))
        grants.removeAll { it.machine == "laptop" && it.placeId == null }
        sent.clear()
        exits.left(listOf("home"))
        assertEquals(listOf("laptop"), sent)
        // The lock went: leaving again (the geofences' initial exit at the next start) sends none.
        sent.clear()
        exits.left(listOf("home"))
        assertTrue(sent.isEmpty())
        // The desk locks the PC.
        exits.left(listOf("desk"))
        assertEquals(listOf("pc"), sent)
    }

    @Test
    fun aLockThatDidNotGoIsSentAgain() = runTest {
        ownersMorning()
        relayUp = false
        assertTrue(exits.left(listOf("home")).isEmpty())
        relayUp = true
        assertEquals(listOf("mac"), exits.left(listOf("home")).map { it.second.key })
    }

    @Test
    fun aFreshFixOutsideThePlaceIsAMissedExit() = runTest {
        ownersMorning()
        // About 1.1 km north of Home, 10 m accuracy, taken 20 s ago.
        val walk = Fix(50.46, 30.52, 10.0, now - 20_000)
        val left = exits.leftByFix(walk, now)
        assertTrue("home" in left)
        exits.left(left)
        assertEquals(listOf("mac", "pc"), sent.sorted())
        // At Home, the fix says nothing about Home.
        assertFalse("home" in exits.leftByFix(Fix(50.4501, 30.52, 10.0, now), now))
        // A rough fix near the edge, or an old one, says nothing either.
        assertFalse("home" in exits.leftByFix(Fix(50.452, 30.52, 200.0, now), now))
        assertFalse("home" in exits.leftByFix(Fix(50.46, 30.52, 10.0, now - 10 * 60_000), now))
    }

    @Test
    fun locationThatNoLongerWatchesTheEdgesLocksEveryMachineAllowedAtAPlace() = runTest {
        ownersMorning()
        // "Allow all the time" taken away, or location turned off.
        assertEquals(listOf("mac", "pc"), exits.unwatched().map { it.second.key }.sorted())
        // Not an exit: no place counts as left.
        assertEquals(0, exits.exitsFrom("home"))
    }

    @Test
    fun aRemovedPlaceLocksNothing() = runTest {
        ownersMorning()
        places = listOf(home.copy(deleted = true), desk)
        exits.left(listOf("home"))
        assertTrue(sent.isEmpty())
        assertFalse("home" in exits.leftByFix(Fix(50.46, 30.52, 10.0, now), now))
    }

    @Test
    fun exitsAreCountedByPlace() = runTest {
        // An answer decided at Home is on its way when the geofences' initial exit for the desk
        // arrives: that is not leaving Home.
        val atHome = exits.exitsFrom("home")
        exits.left(listOf("desk"))
        assertEquals(atHome, exits.exitsFrom("home"))
        exits.left(listOf("home"))
        assertEquals(atHome + 1, exits.exitsFrom("home"))
    }

    @Test
    fun aFixIsTakenOnlyWhileAPlaceIsClaimedAndNotTooOften() {
        // Nothing allowed at a place and no current place: no fix.
        grants = mutableListOf(grant("laptop", null))
        assertFalse(exits.fixDue(null, now, 60_000))
        // Inside a place: one now, none again within the minute, one after it.
        assertTrue(exits.fixDue("home", now, 60_000))
        assertFalse(exits.fixDue("home", now + 30_000, 60_000))
        assertTrue(exits.fixDue("home", now + 61_000, 60_000))
        // A machine allowed at Home, wherever the phone thinks it is.
        grants.add(grant("mac", "home"))
        assertTrue(exits.fixDue(null, now + 200_000, 60_000))
        // No fix came: the next check tries again at once.
        exits.noFix(now + 200_000)
        assertTrue(exits.fixDue(null, now + 200_001, 60_000))
    }

    @Test
    fun anAnswerOnItsWayLocksItsMachineByItsAllowance() = runTest {
        ownersMorning()
        // The Mac's allowance is from Home: found, and locked with the others from there.
        assertTrue(exits.lockAt("home", "mac"))
        assertEquals(listOf("mac"), sent)
        // The relay did not take it: still found, so the caller does not send it again at once.
        grants = mutableListOf(grant("mac", "home"))
        relayUp = false
        assertTrue(exits.lockAt("home", "mac"))
        // "Allow once" at Home set no allowance there: the caller locks the machine itself.
        assertFalse(exits.lockAt("home", "laptop"))
    }
}
