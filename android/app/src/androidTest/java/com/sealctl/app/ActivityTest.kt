package com.sealctl.app

import androidx.compose.foundation.layout.Column
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.assertTextEquals
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performScrollTo
import androidx.compose.ui.test.performTouchInput
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.unit.dp
import androidx.compose.ui.test.assertContentDescriptionContains
import androidx.compose.ui.test.assertCountEquals
import androidx.compose.ui.test.click
import androidx.compose.ui.test.hasContentDescription
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.sealctl.core.LogEntry
import com.sealctl.core.MachineStatus
import com.sealctl.core.app.Event
import com.sealctl.core.app.Machine
import com.sealctl.designsystem.SealctlTheme
import com.sealctl.ui.ActivityList
import com.sealctl.ui.Page
import org.junit.After
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import java.time.LocalDate
import java.time.ZoneId
import java.time.temporal.WeekFields
import java.util.Locale

/**
 * The Activity screen (SPEC.md 11.12): today open, earlier days closed until tapped, and the
 * heatmap below. The uses are a made-up machine's status reports, stored on this test phone
 * through the shared core; no relay is involved.
 */
@RunWith(AndroidJUnit4::class)
class ActivityTest {
    @get:Rule
    val rule = createComposeRule()

    private val engine get() = Graph.engine
    private val key = "A".repeat(43)
    private val zone = ZoneId.systemDefault()
    private val today = LocalDate.now(zone)

    private fun at(date: LocalDate, hour: Int) = date.atTime(hour, 0).atZone(zone).toInstant().toEpochMilli().toULong()

    @Before
    fun seed() {
        engine.store.erase()
        engine.store.apply(
            Event.PairMachine(
                Machine(
                    key = key, boxKey = "", name = "dev@mbp.example.com", os = "macOS 26", model = null, hint = null,
                    pairedAt = 0u, nickname = null, lastSeen = null, lastStatus = null, tagShown = false, flagged = false,
                    relay = "", updated = 0u, deleted = false,
                ),
                null,
            ),
        )
        fun entry(time: ULong, name: String) = LogEntry(time = time, agent = null, repository = null, command = "env", names = listOf(name), own = false)
        val log = listOf(
            entry(System.currentTimeMillis().toULong(), "shop/TODAY_KEY"),
            entry(at(today.minusDays(2), 10), "shop/EARLIER_KEY"),
            entry(at(today.minusDays(2), 11), "shop/EARLIER_KEY"),
            entry(at(today.minusDays(20), 10), "shop/OLD_KEY"),
        )
        engine.store.applyStatus(key, MachineStatus(version = 1u, time = 0u, seq = 1u, state = null, log = log, inventory = emptyList(), migrate = null), engine.offset())
        engine.refreshState()
        rule.setContent { SealctlTheme { Page("Activity", onBack = null) { ActivityList(null) } } }
    }

    @After
    fun clean() {
        engine.store.erase()
        engine.refreshState()
    }

    /** A node read by its accessibility label: rows and day headers carry one label each. */
    private fun desc(text: String) = rule.onNode(hasContentDescription(text, substring = true))

    @Test
    fun todayIsOpenEarlierDaysOpenOnTapOlderDaysAreNotListed() {
        desc("TODAY_KEY").assertIsDisplayed()
        // Two days ago: one header with its count, closed.
        val earlier = rule.onNodeWithTag("day ${today.minusDays(2)}")
        earlier.performScrollTo().assertIsDisplayed()
        earlier.assertContentDescriptionContains("2 uses", substring = true)
        desc("EARLIER_KEY").assertDoesNotExist()
        earlier.performClick()
        rule.onAllNodes(hasContentDescription("EARLIER_KEY", substring = true)).assertCountEquals(2)
        earlier.performClick()
        desc("EARLIER_KEY").assertDoesNotExist()
        // Today closes too.
        rule.onNodeWithTag("day $today").performScrollTo().performClick()
        desc("TODAY_KEY").assertDoesNotExist()
        // Twenty days ago is past the ten days listed.
        rule.onNodeWithTag("day ${today.minusDays(20)}").assertDoesNotExist()
        desc("OLD_KEY").assertDoesNotExist()
    }

    @Test
    fun theHeatmapCountsTheYearAndShowsATappedDay() {
        rule.onNodeWithTag("heatmap").performScrollTo().assertIsDisplayed()
        // The report reached the phone now, so its four uses count today.
        rule.onNodeWithText("4 key uses in the last year").assertIsDisplayed()
        // Today is the last filled cell; the grid opens scrolled to it at the right edge.
        val grid = desc("4 key uses in the last year")
        grid.performScrollTo()
        grid.performTouchInput {
            // Positions are in the visible part of the grid, which ends with today's column:
            // cells of 12 dp, 15 dp apart.
            val row = HeatGrid(today, WeekFields.of(Locale.getDefault()).firstDayOfWeek).days.lastIndex % 7
            click(Offset(width - 9.dp.toPx(), row * 15.dp.toPx() + 6.dp.toPx()))
        }
        rule.onNodeWithTag("heatmap day").performScrollTo().assertIsDisplayed()
            .assertTextEquals(Texts.heatDay(today, 4, 0, Locale.getDefault()))
    }
}
