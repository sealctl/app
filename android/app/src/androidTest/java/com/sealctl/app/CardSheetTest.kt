package com.sealctl.app

import androidx.activity.ComponentActivity
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.material3.Button
import androidx.compose.material3.Text
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.compose.ui.test.onNodeWithText
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import androidx.test.uiautomator.UiDevice
import com.sealctl.designsystem.SealctlTheme
import com.sealctl.ui.CardSheet
import org.junit.Assert.assertEquals
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

/**
 * The approval card's sheet (SPEC.md 11.7) stays until it is answered or closed. A swipe down, a
 * tap outside or back used to hide it while it stayed composed: its window, full screen and
 * empty, then took every touch and the app looked frozen. Touches here go through the window
 * manager (UiDevice), as a finger's do, so a window left on top would swallow them.
 */
@RunWith(AndroidJUnit4::class)
class CardSheetTest {
    @get:Rule
    val rule = createAndroidComposeRule<ComponentActivity>()

    private val device get() = UiDevice.getInstance(InstrumentationRegistry.getInstrumentation())

    private var shown by mutableStateOf(true)
    private var tabTaps by mutableIntStateOf(0)
    private var backs = 0

    /** A screen with a "Tab" button under a card; an expired card closes on back, as the app's does. */
    private fun show(expired: Boolean) {
        rule.setContent {
            SealctlTheme {
                Box(Modifier.fillMaxSize()) {
                    Button({ tabTaps++ }, Modifier.align(Alignment.Center)) { Text("Tab") }
                    if (shown) CardSheet(onBack = { if (expired) shown = false else backs++ }) {
                        Column {
                            Text(if (expired) "dev@mbp.example.com stopped waiting." else "Allow OPENAI_API_KEY?")
                            Button({ shown = false }) { Text("Close") }
                        }
                    }
                }
            }
        }
        rule.waitForIdle()
        card(expired).assertIsDisplayed()
    }

    private fun card(expired: Boolean) =
        rule.onNodeWithText(if (expired) "dev@mbp.example.com stopped waiting." else "Allow OPENAI_API_KEY?")

    /** A real tap at the centre of the node with [text]. */
    private fun tap(text: String) {
        val node = rule.onNodeWithText(text).fetchSemanticsNode()
        val p = node.positionOnScreen
        device.click((p.x + node.size.width / 2).toInt(), (p.y + node.size.height / 2).toInt())
        rule.waitForIdle()
    }

    private fun swipeDown(expired: Boolean) {
        val node = card(expired).fetchSemanticsNode()
        val p = node.positionOnScreen
        device.swipe((p.x + node.size.width / 2).toInt(), p.y.toInt(), device.displayWidth / 2, device.displayHeight - 10, 20)
        rule.waitForIdle()
    }

    /** A tap on the dimmed screen above the sheet. */
    private fun tapOutside() {
        device.click(device.displayWidth / 2, device.displayHeight / 6)
        rule.waitForIdle()
    }

    private fun tabStillWorks() {
        // The sheet's window leaves the window manager a moment after the sheet leaves the
        // composition: the activity has the focus again once it is gone. A window left behind
        // keeps the focus, and this times out.
        rule.waitUntil(5_000) { rule.activity.hasWindowFocus() }
        val before = tabTaps
        tap("Tab")
        rule.runOnIdle { assertEquals(before + 1, tabTaps) }
    }

    @Test
    fun aWaitingCardStaysThroughSwipeBackAndATapOutside() {
        show(expired = false)
        swipeDown(expired = false)
        card(false).assertIsDisplayed()
        device.pressBack()
        rule.waitForIdle()
        card(false).assertIsDisplayed()
        tapOutside()
        card(false).assertIsDisplayed()
        // Back was the app's to handle (it leaves the app), not the sheet's.
        rule.runOnIdle { assertEquals(1, backs) }
        // Its buttons still answer, and once it is closed the screen under it takes taps.
        tap("Close")
        tabStillWorks()
    }

    @Test
    fun anExpiredCardStaysUntilClosedAndBackClosesIt() {
        show(expired = true)
        swipeDown(expired = true)
        card(true).assertIsDisplayed()
        tapOutside()
        card(true).assertIsDisplayed()
        tap("Close")
        tabStillWorks()

        // Shown again, back closes it like Close does.
        rule.runOnIdle { shown = true }
        rule.waitForIdle()
        card(true).assertIsDisplayed()
        device.pressBack()
        rule.waitForIdle()
        tabStillWorks()
    }
}
