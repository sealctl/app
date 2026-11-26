package com.sealctl.app

import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithText
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.sealctl.core.Place as PlaceKind
import com.sealctl.core.app.Event
import com.sealctl.core.app.LocationAccess
import com.sealctl.core.app.TrustedPlace
import com.sealctl.designsystem.SealctlTheme
import com.sealctl.places.LocationPermissions
import com.sealctl.ui.Page
import com.sealctl.ui.PlacesAlwaysBanner
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

/**
 * Places by the location permission (SPEC.md 9.4, 11.9), with the permission given at the
 * engine's [LocationPermissions] boundary: a trusted place counts only with location "Allow all
 * the time", and the banner asks for it while it is missing. The owner's phone had precise
 * location while in use only: every approval carried `other` (10 minutes, no growth).
 */
@RunWith(AndroidJUnit4::class)
class PlacesTest {
    @get:Rule
    val rule = createComposeRule()

    private val engine get() = Graph.engine

    private class Permissions(var foreground: Boolean, var background: Boolean) : LocationPermissions {
        override fun hasForeground() = foreground
        override fun hasBackground() = background
    }

    private val permissions = Permissions(foreground = true, background = false)

    @Before
    fun seed() {
        engine.store.erase()
        engine.store.apply(Event.AddPlace(TrustedPlace("home", "Home", 50.45, 30.52, 150.0, 1u, 0u, false, false)))
        engine.refreshState()
        engine.permissions = permissions
    }

    @After
    fun clean() {
        engine.permissions = engine.places
        engine.currentPlace.value = null
        engine.store.erase()
        engine.refreshState()
    }

    @Test
    fun withoutAllowAllTheTimeTheReplyCarriesNoneNotOther() {
        // The owner's phone: precise location while in use, no background, the geofences silent.
        assertEquals(LocationAccess.WHILE_IN_USE, engine.location())
        assertEquals(PlaceKind.NO_LOCATION, engine.placeKind())
        // A place the phone last knew does not count either: leaving it would go unnoticed.
        engine.currentPlace.value = "home"
        assertEquals(PlaceKind.NO_LOCATION, engine.placeKind())
        assertEquals(null, engine.here())
        assertFalse(engine.delayLifted())
        // "Allow all the time": the place counts, and away from it is `other`.
        permissions.background = true
        assertEquals(PlaceKind.TRUSTED, engine.placeKind())
        assertEquals("home", engine.here())
        engine.currentPlace.value = null
        assertEquals(PlaceKind.OTHER, engine.placeKind())
        // No location at all.
        permissions.foreground = false
        assertEquals(PlaceKind.NO_LOCATION, engine.placeKind())
    }

    @Test
    fun theBannerAsksForAllTheTimeWhileItIsMissing() {
        rule.setContent { SealctlTheme { Page("Machines", onBack = null) { PlacesAlwaysBanner() } } }
        rule.onNodeWithText(Texts.PLACES_ALWAYS).assertIsDisplayed()
        rule.onNodeWithText("Open settings").assertIsDisplayed()
    }

    @Test
    fun noBannerWithAllTheTime() {
        permissions.background = true
        rule.setContent { SealctlTheme { Page("Machines", onBack = null) { PlacesAlwaysBanner() } } }
        rule.onNodeWithText(Texts.PLACES_ALWAYS).assertDoesNotExist()
    }

    @Test
    fun noBannerWithoutPlaces() {
        engine.store.erase()
        engine.refreshState()
        rule.setContent { SealctlTheme { Page("Machines", onBack = null) { PlacesAlwaysBanner() } } }
        rule.onNodeWithText(Texts.PLACES_ALWAYS).assertDoesNotExist()
    }
}
