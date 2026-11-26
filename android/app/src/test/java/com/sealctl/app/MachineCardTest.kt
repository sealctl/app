package com.sealctl.app

import com.sealctl.core.app.Machine
import com.sealctl.core.app.SessionStatus
import com.sealctl.core.app.machineModelName
import com.sealctl.core.app.machineSession
import com.sealctl.core.app.machineShortName
import com.sealctl.designsystem.MachineState
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** The machine card on the Machines list (SPEC.md 11.17), through the shared crate as the screen gets it. */
class MachineCardTest {
    private val now = 1_800_000_000_000L
    private val hour = 3_600_000L
    private val macMini = Machine(
        key = "A".repeat(43), boxKey = "", name = "dev@Devs-Mac-mini.local", os = "macOS 26.1", model = "Mac16,10", hint = null,
        pairedAt = 0u, nickname = null, lastSeen = (now - hour).toULong(), lastStatus = null, tagShown = false, flagged = false,
        relay = "", updated = 0u, deleted = false,
    )

    private fun card(m: Machine, row: String = "Locked · last report 1 h ago") =
        MachineView(m, machineShortName(m), MachineState.Locked, row, "", null)

    @Test
    fun shortNameAndModel() {
        assertEquals("Devs-Mac-mini", machineShortName(macMini))
        assertEquals("Work laptop", machineShortName(macMini.copy(nickname = "Work laptop")))
        assertEquals("mbp.example.com", machineShortName(macMini.copy(name = "dev@mbp.example.com")))
        assertEquals("Mac mini", machineModelName("Mac16,10"))
        assertEquals("MacBook Pro", machineModelName("MacBookPro18,3"))
        assertEquals("ThinkPad X1 Carbon Gen 11", machineModelName("ThinkPad X1 Carbon Gen 11"))
    }

    @Test
    fun threeLinesAndOneLabel() {
        val v = card(macMini)
        assertEquals("Devs-Mac-mini", v.name)
        assertEquals("Mac mini · seen 1 h ago", v.sub(now))
        assertNull(v.unseen(now))
        assertEquals("Devs-Mac-mini, Locked · last report 1 h ago, Mac mini, seen 1 h ago", v.label(now))
    }

    @Test
    fun noModelAndLongUnseen() {
        val v = card(macMini.copy(model = null, flagged = true, lastSeen = (now - 94 * 24 * hour).toULong()), "Locked")
        assertEquals("seen 94 days ago", v.sub(now))
        assertEquals("Not seen for 94 days", v.unseen(now))
        assertEquals("Devs-Mac-mini, Locked, seen 94 days ago, Not seen for 94 days", v.label(now))
        assertNull(card(macMini.copy(model = "")).model)
    }

    private val min = 60_000L

    /** An Open status reported at [now]: [left] seconds left, idle [idle] seconds, allowance [allow]. */
    private fun open(left: Long, idle: Long?, allow: Long?, stop: Long? = null) = machineSession(
        SessionStatus(
            session = "open", left = left.toULong(), idle = idle?.toULong(), allow = allow?.toULong(), stop = stop?.toULong(),
            place = null, reportedAt = now.toULong(), seq = 1u,
        ),
    )

    @Test
    fun activeWhileTheMachineWorks() {
        val s = open(14_390, 10, 14_400)
        // no countdown: the same row a second, a minute and two minutes later
        for (later in listOf(0L, 1_000L, min, 2 * min)) assertEquals("Open · active", MachineView.openRow(s, now + later))
        assertTrue(MachineView.isActive(s, now + 2 * min))
        // no status 3 minutes after its last work: idle, counted from that work
        assertFalse(MachineView.isActive(s, now + 170_000))
        assertEquals("Open · idle 3 min · locks at ${Texts.time(now + 14_390_000)}", MachineView.openRow(s, now + 170_000))
    }

    @Test
    fun idleWithTheTimeItLocks() {
        val s = open(13_680, 720, 14_400, stop = now + 10 * 60 * min)
        val at = Texts.time(now + 13_680_000)
        assertEquals("Open · idle 12 min · locks at $at", MachineView.openRow(s, now))
        assertEquals("Open · idle 17 min · locks at $at", MachineView.openRow(s, now + 5 * min))
        // the hard stop first when it is sooner
        val stop = now + 30 * min
        assertEquals("Open · idle 12 min · locks at ${Texts.time(stop)}", MachineView.openRow(open(13_680, 720, 14_400, stop), now))
        // past the time it locks: not Open
        assertNull(MachineView.openRow(open(600, 3_000, 3_600), now + 10 * min))
    }

    @Test
    fun aCliWithoutIdleTimeCountsDown() {
        val s = open(600, null, null)
        assertEquals("Open · 10 min left", MachineView.openRow(s, now))
        assertEquals("Open · 9 min left", MachineView.openRow(s, now + min))
        assertNull(MachineView.openRow(s, now + 10 * min))
    }
}
