package com.sealctl.app

import android.Manifest
import android.app.NotificationManager
import android.os.Build
import androidx.activity.compose.setContent
import androidx.compose.ui.test.hasText
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.sealctl.core.app.DelayedAction
import com.sealctl.core.app.LocalEvent
import com.sealctl.designsystem.SealctlTheme
import com.sealctl.ui.DelayView
import com.sealctl.ui.PhoneActionButtons
import com.sealctl.ui.ShowWordsScreen
import kotlinx.coroutines.runBlocking
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

/**
 * A level 3 action on the phone after its delay (SPEC.md 10.2, 11.23): the "Ready" alarm through
 * the real AlarmManager and its notification, the delay screen turning ready at `releaseAt`
 * while open, "Start again" once expired, and the start button showing a running action rather
 * than starting another. The records are put in this test phone's store; no relay is involved
 * (the relay check at the alarm gets no answer without phone keys, and the note is posted).
 */
@RunWith(AndroidJUnit4::class)
class PhoneActionTest {
    @get:Rule
    val rule = createAndroidComposeRule<MainActivity>()

    private val engine get() = Graph.engine
    private val context get() = InstrumentationRegistry.getInstrumentation().targetContext
    private val alarms get() = SystemReadyAlarms(context)
    private val ids = mutableListOf<String>()

    @Before
    fun clean() {
        if (Build.VERSION.SDK_INT >= 33) {
            InstrumentationRegistry.getInstrumentation().uiAutomation.grantRuntimePermission(context.packageName, Manifest.permission.POST_NOTIFICATIONS)
        }
    }

    @After
    fun forget() {
        for (id in ids) {
            if (engine.phoneKeys() != null) runBlocking { runCatching { engine.relay.cancelDelayed(id, userTapped = false) } }
            alarms.cancel(id)
            engine.applyLocal(LocalEvent.RemoveDelayed(id))
            context.getSystemService(NotificationManager::class.java).cancel(Ready.tag(id), Ready.tag(id).hashCode())
        }
    }

    private fun put(what: String, releaseIn: Long, expiresIn: Long, state: String = "waiting"): DelayedAction {
        val now = System.currentTimeMillis()
        val d = DelayedAction("t" + randomTestId(), what, null, (now + releaseIn).toULong(), (now + expiresIn).toULong(), state, null, (now - 60_000).toULong())
        ids += d.id
        engine.applyLocal(LocalEvent.PutDelayed(d))
        return d
    }

    private fun randomTestId() = java.util.UUID.randomUUID().toString().replace("-", "").take(20)

    private fun shows(text: String) = rule.onAllNodes(hasText(text, substring = true)).fetchSemanticsNodes().isNotEmpty()

    private fun waitFor(text: String, ms: Long = 15_000) = rule.waitUntil(ms) { shows(text) }

    private fun readyNoteShown(id: String) =
        context.getSystemService(NotificationManager::class.java).activeNotifications.any { it.tag == Ready.tag(id) }

    /**
     * "Alarms & reminders" allowed for this app (Android 12 and later; always allowed before).
     * Taking it away kills the app, so the inexact path is covered by the unit tests.
     */
    private fun allowExactAlarms() {
        if (Build.VERSION.SDK_INT < 31) return
        InstrumentationRegistry.getInstrumentation().uiAutomation
            .executeShellCommand("appops set ${context.packageName} SCHEDULE_EXACT_ALARM allow").close()
        rule.waitUntil(5_000) { alarms.canExact() }
    }

    @Test
    fun theAlarmIsSetAndACancelTakesItBack() {
        val d = put("words", releaseIn = 3_600_000, expiresIn = 7_200_000)
        Ready.schedule(d.id, d.what, d.releaseAt.toLong())
        assertTrue(alarms.isSet(d.id))
        Ready.cancel(d.id)
        assertFalse(alarms.isSet(d.id))
    }

    /**
     * At `releaseAt` the alarm wakes the app, which asks the relay and posts "Ready" with the
     * time left to finish. On a phone with relay keys the record is registered with the relay
     * (a debug build's relay, the fake one), so the relay check finds it waiting.
     */
    @Test
    fun theAlarmPostsReadyAtReleaseAt() {
        allowExactAlarms()
        val d = if (engine.phoneKeys() != null) runBlocking {
            val id = com.sealctl.core.app.randomId()
            val r = engine.relay.addDelayed(id, 2)
            DelayedAction(id, "words", null, r.releaseAt.toULong(), r.expires.toULong(), "waiting", null, System.currentTimeMillis().toULong())
                .also { ids += id; engine.applyLocal(LocalEvent.PutDelayed(it)) }
        } else put("words", releaseIn = 2_000, expiresIn = 120_000)
        Ready.schedule(d.id, d.what, d.releaseAt.toLong())
        rule.waitUntil(30_000) { readyNoteShown(d.id) }
        val n = context.getSystemService(NotificationManager::class.java).activeNotifications.first { it.tag == Ready.tag(d.id) }
        assertEquals(Texts.ready("words"), n.notification.extras.getCharSequence("android.title").toString())
    }

    /** A reboot or a force stop clears alarms: the app sets them again for actions still waiting. */
    @Test
    fun alarmsAreSetAgainForActionsStillWaiting() {
        val waiting = put("delete", releaseIn = 3_600_000, expiresIn = 7_200_000)
        val cancelled = put("words", releaseIn = 3_600_000, expiresIn = 7_200_000, state = "cancelled")
        alarms.cancel(waiting.id)
        assertFalse(alarms.isSet(waiting.id))
        runBlocking { engine.restoreReadyAlarms(afterBoot = false) }
        assertTrue(alarms.isSet(waiting.id))
        assertFalse(alarms.isSet(cancelled.id))
    }

    /** Open at `releaseAt`, the screen turns ready by itself: "Ready until …" and Show my words. */
    @Test
    fun theDelayScreenTurnsReadyWhileOpen() {
        val d = put("words", releaseIn = 3_000, expiresIn = 120_000)
        var ready = 0
        rule.activity.setContent {
            SealctlTheme { DelayView(d.id, "Showing your words", PhoneActionButtons("words", false, null, onReady = { ready++ }, onStartAgain = {})) }
        }
        waitFor("min left", 5_000)
        rule.onNodeWithText("Cancel").assertExists()
        waitFor(Texts.readyUntil(d.expires.toLong()))
        rule.onNodeWithText("Show my words").performClick()
        assertEquals(1, ready)
    }

    /** After `expires`, without the relay saying so: "This waited too long. Start again." */
    @Test
    fun anExpiredActionOffersStartAgain() {
        // Ready for a moment, then expired; before the relay's list is read again (15 s), so
        // the screen goes by the time alone.
        val d = put("delete", releaseIn = 1_500, expiresIn = 4_000)
        var again = 0
        rule.activity.setContent {
            SealctlTheme { DelayView(d.id, "Deleting your relay data", PhoneActionButtons("delete", false, null, onReady = {}, onStartAgain = { again++ })) }
        }
        waitFor(Texts.readyUntil(d.expires.toLong()), 5_000)
        rule.onNodeWithText("Finish").assertExists()
        waitFor("This waited too long. Start again.")
        rule.onNodeWithText(Texts.START_AGAIN).performClick()
        assertEquals(1, again)
    }

    /** While Show words waits, its screen shows that delay instead of a start button. */
    @Test
    fun showWordsWhileOneWaitsShowsItInsteadOfStarting() {
        val d = put("words", releaseIn = 3_600_000, expiresIn = 7_200_000)
        rule.activity.setContent { SealctlTheme { ShowWordsScreen(rule.activity) } }
        waitFor("goes ahead at ${Texts.time(d.releaseAt.toLong())}", 5_000)
        assertFalse(shows(Texts.CONFIRM))
        assertTrue(shows("Showing your words"))
    }
}
