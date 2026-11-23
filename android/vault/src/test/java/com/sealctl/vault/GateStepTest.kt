package com.sealctl.vault

import com.sealctl.vault.Vault.GateStep
import org.junit.Assert.assertEquals
import org.junit.Test

/** The gate rule of SPEC.md 9.6: the first gate, like a new one after an enrolment change, needs the card. */
class GateStepTest {
    @Test
    fun aStoredGateIsChecked() {
        assertEquals(GateStep.CHECK, Vault.gateStep(hasKey = true, hasFile = true, cardPassed = false))
        assertEquals(GateStep.CHECK, Vault.gateStep(hasKey = true, hasFile = true, cardPassed = true))
    }

    @Test
    fun theFirstGateNeedsTheCard() {
        assertEquals(GateStep.CARD_FIRST, Vault.gateStep(hasKey = false, hasFile = false, cardPassed = false))
        assertEquals(GateStep.MAKE, Vault.gateStep(hasKey = false, hasFile = false, cardPassed = true))
    }

    @Test
    fun aHalfMadeGateIsNoGate() {
        // A prompt cancelled while making the gate leaves the key without its file.
        assertEquals(GateStep.CARD_FIRST, Vault.gateStep(hasKey = true, hasFile = false, cardPassed = false))
        assertEquals(GateStep.MAKE, Vault.gateStep(hasKey = true, hasFile = false, cardPassed = true))
        assertEquals(GateStep.CARD_FIRST, Vault.gateStep(hasKey = false, hasFile = true, cardPassed = false))
    }
}
