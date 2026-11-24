package com.sealctl.app

/** The level 3 delay (SPEC.md 9.6), apart from the engine so it can be tested. */
internal object Delays {
    /** Two hours: a level 3 approval away from a trusted place. */
    const val LEVEL3_SECS = 7200

    /**
     * The delay of a level 2 or 3 confirm, in seconds, decided when the person confirms: the
     * two hours at level 3 unless the place the phone is in now lifts them ([liftedNow]), and
     * never less than [arrival], the verdict's delay from when the request arrived (the phone
     * may have left the place, or the place been removed, while the card was open). [testSecs]
     * (debug builds only, 0 otherwise) shortens a delay that applies.
     */
    fun atConfirm(arrival: Int, level: Int, liftedNow: Boolean, testSecs: Int = 0): Int =
        shortened(maxOf(arrival, if (level >= 3 && !liftedNow) LEVEL3_SECS else 0), testSecs)

    /** [secs], or [testSecs] instead when a delay applies and a test build asks for it. */
    fun shortened(secs: Int, testSecs: Int): Int = if (secs > 0 && testSecs > 0) testSecs else secs
}
