package com.sealctl.app

import com.sealctl.core.app.Machine
import com.sealctl.core.app.machineModelName
import com.sealctl.core.app.machineShortName
import com.sealctl.designsystem.MachineState
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
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
}
