package com.sealctl.app

import com.sealctl.core.app.ActivityCounts
import com.sealctl.core.app.DailyCount
import com.sealctl.core.app.UsageEntry
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.time.DayOfWeek
import java.time.LocalDate
import java.time.Month
import java.time.ZoneId
import java.time.ZoneOffset
import java.util.Locale

/** The Activity screen's month titles, days and heatmap grid (SPEC.md 11.12). */
class ActivityDaysTest {
    @Test
    fun monthTitlesAreStandaloneAndCapitalised() {
        // Inside a date Polish says "listopada"; on its own, as a title, "Listopad".
        assertEquals("Listopad", Texts.monthTitle("2026-11", Locale.forLanguageTag("pl")))
        assertEquals("Листопад", Texts.monthTitle("2026-11", Locale.forLanguageTag("uk")))
        assertEquals("Ноябрь", Texts.monthTitle("2026-11", Locale.forLanguageTag("ru")))
        assertEquals("Styczeń", Texts.monthTitle("2027-01", Locale.forLanguageTag("pl")))
        assertEquals("November", Texts.monthTitle("2026-11", Locale.ENGLISH))
        assertEquals("Lis", Texts.monthName(Month.NOVEMBER, Locale.forLanguageTag("pl"), java.time.format.TextStyle.SHORT_STANDALONE).take(3))
    }

    @Test
    fun summaryFiguresAreSingularForOne() {
        assertEquals("312 keys used on 3 machines", Texts.keysUsed(312, 3))
        assertEquals("1 key used on 1 machine", Texts.keysUsed(1, 1))
        assertEquals("0 keys used on 0 machines", Texts.keysUsed(0, 0))
        assertEquals("2 keys used on 1 machine", Texts.keysUsed(2, 1))
        assertEquals("1 request declined", Texts.requestsDeclined(1))
        assertEquals("4 requests declined", Texts.requestsDeclined(4))
        assertEquals("0 requests declined", Texts.requestsDeclined(0))
    }

    private val utc: ZoneId = ZoneOffset.UTC
    private val today = LocalDate.of(2026, 11, 25)

    private fun at(date: LocalDate, hour: Int, outcome: String = "one_tap") = UsageEntry(
        time = date.atTime(hour, 0).toInstant(ZoneOffset.UTC).toEpochMilli().toULong(), machine = "m", key = "K",
        agent = null, repo = null, command = null, outcome = outcome, kind = null,
    )

    @Test
    fun theNewestDayAndTheTenBeforeTodayAreListed() {
        val entries = listOf(
            at(today, 9), at(today, 8, "denied"),
            at(today.minusDays(1), 22),
            at(today.minusDays(10), 7), // the oldest day listed
            at(today.minusDays(11), 7), // too old
        )
        val days = ActivityDays.group(entries, today, utc)
        assertEquals(listOf(today, today.minusDays(1), today.minusDays(10)), days.map { it.date })
        assertEquals(ActivityCounts(1u, 1u), days[0].counts)
        assertEquals("1 use · 1 declined", Texts.dayCounts(days[0].counts))
        assertEquals("37 uses", Texts.dayCounts(ActivityCounts(37u, 0u)))
    }

    @Test
    fun aNewestDayOlderThanTheWindowIsStillListed() {
        val days = ActivityDays.group(listOf(at(today.minusDays(30), 9), at(today.minusDays(40), 9)), today, utc)
        assertEquals(listOf(today.minusDays(30)), days.map { it.date })
        assertTrue(ActivityDays.group(emptyList(), today, utc).isEmpty())
    }

    @Test
    fun theGridEndsWithTodaysWeekAndStartsOnTheLocalesFirstDay() {
        // 2026-11-25 is a Wednesday.
        val monday = HeatGrid(today, DayOfWeek.MONDAY)
        assertEquals(DayOfWeek.MONDAY, monday.start.dayOfWeek)
        assertEquals(LocalDate.of(2025, 11, 24), monday.start)
        assertEquals(52 * 7 + 3, monday.days.size)
        assertEquals(today, monday.days.last())
        assertEquals(listOf(0, 2, 4), monday.labelledRows())
        val sunday = HeatGrid(today, DayOfWeek.SUNDAY)
        assertEquals(DayOfWeek.SUNDAY, sunday.start.dayOfWeek)
        assertEquals(listOf(1, 3, 5), sunday.labelledRows())
        assertEquals(null, monday.index(52, 3)) // Thursday, after today
        assertEquals(monday.days.lastIndex, monday.index(52, 2))
        // A label where each month begins, the first partial month left out when cramped.
        val labels = monday.monthStarts().map { monday.date(it, 0).month }
        assertEquals(Month.DECEMBER, labels.first())
        assertEquals(12, labels.size)
    }

    @Test
    fun cellsCarryTheCountsAndTheirLevels() {
        val grid = HeatGrid(today, DayOfWeek.MONDAY)
        val cells = grid.cells(listOf(DailyCount(today.toString(), 40u, 2u), DailyCount(today.minusDays(1).toString(), 1u, 0u)))
        assertEquals(grid.days.size, cells.size)
        assertEquals(HeatGrid.Cell(today, 40, 2, 4), cells.last())
        assertEquals(1, cells[cells.size - 2].level)
        assertEquals(0, cells.first().level)
        assertEquals("1,204 key uses in the last year", Texts.heatTitle(1204, Locale.US))
        assertEquals("Nov 25, 2026: 1 key use, 2 declined", Texts.heatDay(today, 1, 2, Locale.US))
    }

    @Test
    fun aNewPageKeepsTheRowsAndCellsThatDidNotChange() {
        fun row(subject: String) = Texts.time(0) to com.sealctl.core.app.ActivityRow(subject, "In session", com.sealctl.core.app.ActivityTone.NORMAL, emptyList())
        fun cell(used: Long) = HeatGrid.Cell(today, used, 0, 1)
        val old = ActivityPage(
            listOf(
                ActivityPage.ShownDay(today, ActivityCounts(2u, 0u), listOf(row("A"), row("B"))),
                ActivityPage.ShownDay(today.minusDays(1), ActivityCounts(1u, 0u), listOf(row("C"))),
            ),
            listOf(cell(3)),
        )
        // Read again after one more use today: equal, but new objects.
        val read = ActivityPage(
            listOf(
                ActivityPage.ShownDay(today, ActivityCounts(3u, 0u), listOf(row("NEW"), row("A"), row("B"))),
                ActivityPage.ShownDay(today.minusDays(1), ActivityCounts(1u, 0u), listOf(row("C"))),
            ),
            listOf(cell(3)),
        )
        val page = read.reusing(old)
        assertEquals(read, page)
        // The rows already shown are the same objects, so the screen leaves them as drawn.
        assertTrue(page.days[0].rows[1] === old.days[0].rows[0])
        assertTrue(page.days[0].rows[2] === old.days[0].rows[1])
        assertTrue(page.days[0].rows[0] === read.days[0].rows[0])
        assertTrue(page.days[1] === old.days[1])
        assertTrue(page.cells === old.cells)
    }
}
