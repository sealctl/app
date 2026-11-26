package com.sealctl.app

import com.sealctl.core.Place as PlaceKind
import com.sealctl.core.app.LocationAccess
import com.sealctl.core.app.TrustedPlace
import com.sealctl.core.app.placeKind
import com.sealctl.places.PlaceMemory
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** Where the phone is, as far as places go (SPEC.md 9.4, 11.9). */
class PlaceRulesTest {
    private fun place(id: String, deleted: Boolean = false) =
        TrustedPlace(id, "Home", 50.45, 30.52, 150.0, 1u, 0u, deleted, false)

    private val home = listOf(place("home"))

    /** The place kind the reply carries, as [Engine.placeKind] computes it. */
    private fun kind(foreground: Boolean, background: Boolean, current: String?, places: List<TrustedPlace> = home): PlaceKind {
        val access = PlaceRules.access(foreground, background)
        return placeKind(access, PlaceRules.here(current, access, places))
    }

    @Test
    fun permissionsMapToTheCoresAccess() {
        assertEquals(LocationAccess.OFF, PlaceRules.access(foreground = false, background = false))
        assertEquals(LocationAccess.OFF, PlaceRules.access(foreground = false, background = true))
        assertEquals(LocationAccess.WHILE_IN_USE, PlaceRules.access(foreground = true, background = false))
        assertEquals(LocationAccess.ALWAYS, PlaceRules.access(foreground = true, background = true))
    }

    @Test
    fun withoutAllowAllTheTimeTheReplyCarriesNoneNeverOther() {
        // The owner's phone: precise location while in use, a trusted place, no background
        // permission. Before, every approval carried `other` (10 minutes, no growth).
        assertEquals(PlaceKind.NO_LOCATION, kind(foreground = true, background = false, current = null))
        // Even a place it last knew does not count: leaving it would go unnoticed.
        assertEquals(PlaceKind.NO_LOCATION, kind(foreground = true, background = false, current = "home"))
        assertEquals(PlaceKind.NO_LOCATION, kind(foreground = false, background = false, current = null))
        // All the time: trusted inside, other outside.
        assertEquals(PlaceKind.TRUSTED, kind(foreground = true, background = true, current = "home"))
        assertEquals(PlaceKind.OTHER, kind(foreground = true, background = true, current = null))
        // A removed place stops counting at once.
        assertEquals(PlaceKind.OTHER, kind(foreground = true, background = true, current = "home", places = listOf(place("home", deleted = true))))
    }

    @Test
    fun theBannerShowsWhilePlacesExistWithoutAllTheTime() {
        assertTrue(PlaceRules.needsAlways(LocationAccess.WHILE_IN_USE, home))
        assertTrue(PlaceRules.needsAlways(LocationAccess.OFF, home))
        assertFalse(PlaceRules.needsAlways(LocationAccess.ALWAYS, home))
        assertFalse(PlaceRules.needsAlways(LocationAccess.WHILE_IN_USE, emptyList()))
        assertFalse(PlaceRules.needsAlways(LocationAccess.WHILE_IN_USE, listOf(place("home", deleted = true))))
    }

    @Test
    fun theCurrentPlaceComesBackAfterARestartOnlyWhileEveryExitWouldHaveBeenSeen() {
        val saved = PlaceMemory.Saved("home", boot = 7)
        val live = listOf("home")
        // The process was ended for memory: same boot, geofences still registered.
        assertEquals("home", PlaceMemory.restore(saved, boot = 7, registered = true, always = true, live = live))
        // A reboot, or a force stop or update that cancelled the geofences: an exit may have been missed.
        assertNull(PlaceMemory.restore(saved, boot = 8, registered = true, always = true, live = live))
        assertNull(PlaceMemory.restore(saved, boot = 7, registered = false, always = true, live = live))
        // Location no longer allowed all the time, or the place removed.
        assertNull(PlaceMemory.restore(saved, boot = 7, registered = true, always = false, live = live))
        assertNull(PlaceMemory.restore(saved, boot = 7, registered = true, always = true, live = emptyList()))
        assertNull(PlaceMemory.restore(null, boot = 7, registered = true, always = true, live = live))
    }
}
