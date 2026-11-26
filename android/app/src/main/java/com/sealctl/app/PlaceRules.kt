package com.sealctl.app

import com.sealctl.core.app.LocationAccess
import com.sealctl.core.app.TrustedPlace

/** Where the phone is, as far as places go (SPEC.md 9.4, 11.9). */
object PlaceRules {
    /** The location access the shared core decides with. */
    fun access(foreground: Boolean, background: Boolean): LocationAccess = when {
        !foreground -> LocationAccess.OFF
        !background -> LocationAccess.WHILE_IN_USE
        else -> LocationAccess.ALWAYS
    }

    /**
     * The trusted place that counts now: the one the phone is inside, while leaving it would be
     * noticed (location all the time) and it is still trusted. Null otherwise.
     */
    fun here(current: String?, access: LocationAccess, places: List<TrustedPlace>): String? =
        current?.takeIf { id -> access == LocationAccess.ALWAYS && places.any { it.id == id && !it.deleted } }

    /** Places exist, but without location all the time they count for nothing: say so (11.9). */
    fun needsAlways(access: LocationAccess, places: List<TrustedPlace>): Boolean =
        access != LocationAccess.ALWAYS && places.any { !it.deleted }
}
