package com.sealctl.app

import org.junit.Assert.assertEquals
import org.junit.Test

/** The level 3 delay of a confirm (SPEC.md 9.6). */
class DelaysTest {
    @Test
    fun theDelayIsDecidedAtTheConfirm() {
        // Arrived at a trusted place (no delay), confirmed after leaving it: two hours.
        assertEquals(7200, Delays.atConfirm(arrival = 0, level = 3, liftedNow = false))
        // Still at the trusted place: at once.
        assertEquals(0, Delays.atConfirm(arrival = 0, level = 3, liftedNow = true))
        // Arrived away, confirmed at a trusted place: never shorter than when it arrived.
        assertEquals(7200, Delays.atConfirm(arrival = 7200, level = 3, liftedNow = true))
        // Level 2 has no delay.
        assertEquals(0, Delays.atConfirm(arrival = 0, level = 2, liftedNow = false))
    }

    @Test
    fun aTestBuildShortensOnlyADelayThatApplies() {
        assertEquals(5, Delays.atConfirm(arrival = 0, level = 3, liftedNow = false, testSecs = 5))
        assertEquals(5, Delays.atConfirm(arrival = 7200, level = 3, liftedNow = true, testSecs = 5))
        assertEquals(0, Delays.atConfirm(arrival = 0, level = 3, liftedNow = true, testSecs = 5))
        assertEquals(0, Delays.atConfirm(arrival = 0, level = 2, liftedNow = false, testSecs = 5))
    }
}
