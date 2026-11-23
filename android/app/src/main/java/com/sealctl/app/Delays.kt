package com.sealctl.app

/** The level 3 delay (SPEC.md 9.6), apart from the engine so it can be tested. */
internal object Delays {
    /** Two hours: a level 3 approval away from a trusted place. */
    const val LEVEL3_SECS = 7200

    /**
     * The delay of a level 2 or 3 confirm, in seconds. [arrival] is the verdict's delay from
     * when the request arrived, [level] its confirmation level, and [liftedNow] whether the
     * place the phone is in at the confirm lifts the delay. [testSecs] (debug builds only, 0
     * otherwise) shortens a delay that applies.
     */
    fun atConfirm(arrival: Int, level: Int, liftedNow: Boolean, testSecs: Int = 0): Int =
        shortened(arrival, testSecs)

    /** [secs], or [testSecs] instead when a delay applies and a test build asks for it. */
    fun shortened(secs: Int, testSecs: Int): Int = if (secs > 0 && testSecs > 0) testSecs else secs
}
