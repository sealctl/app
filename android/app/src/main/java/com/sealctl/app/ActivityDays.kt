package com.sealctl.app

import com.sealctl.core.app.ActivityCounts
import com.sealctl.core.app.ActivityRow
import com.sealctl.core.app.DailyCount
import com.sealctl.core.app.Machine
import com.sealctl.core.app.Store
import com.sealctl.core.app.UsageEntry
import com.sealctl.core.app.activityCounts
import com.sealctl.core.app.activityRow
import com.sealctl.core.app.heatLevels
import java.time.DayOfWeek
import java.time.Instant
import java.time.LocalDate
import java.time.ZoneId
import java.time.temporal.TemporalAdjusters

/**
 * The days of the Activity log (SPEC.md 11.12): the newest day with entries, open, and the
 * days with entries among the ten before today, closed. Older days are not listed.
 */
object ActivityDays {
    /** Calendar days before today that are listed. */
    const val DAYS_BEFORE = 10L

    data class Day(val date: LocalDate, val entries: List<UsageEntry>, val counts: ActivityCounts)

    /** The days to list, newest first; the first one opens. */
    fun load(store: Store, machine: String?, today: LocalDate, zone: ZoneId): List<Day> {
        var since = today.minusDays(DAYS_BEFORE)
        val newest = store.usage(machine, null, 1u).firstOrNull()?.let { dateOf(it, zone) }
        if (newest != null && newest < since) since = newest
        val from = since.atStartOfDay(zone).toInstant().toEpochMilli()
        return group(store.usageSince(machine, from.toULong()), today, zone)
    }

    /** `entries` (newest first) by local day: the newest day, and the days from ten before today on. */
    fun group(entries: List<UsageEntry>, today: LocalDate, zone: ZoneId): List<Day> {
        val byDay = entries.groupBy { dateOf(it, zone) }
        val newest = byDay.keys.maxOrNull() ?: return emptyList()
        val from = today.minusDays(DAYS_BEFORE)
        return byDay.filterKeys { it >= from || it == newest }
            .toSortedMap(reverseOrder())
            .map { (d, list) -> Day(d, list, activityCounts(list)) }
    }

    fun dateOf(e: UsageEntry, zone: ZoneId): LocalDate = Instant.ofEpochMilli(e.time.toLong()).atZone(zone).toLocalDate()
}

/**
 * What the Activity screen shows from the store (SPEC.md 11.12): the listed days with their
 * rows, and on the main tab the heatmap's cells. Read off the main thread: the store is one
 * connection behind a lock, which a sync, a prune or a status report may hold.
 */
data class ActivityPage(
    val days: List<ShownDay>,
    val cells: List<HeatGrid.Cell>?,
    /** The machines the rows were made with, as passed to the shared core. */
    val machines: Map<String, Machine> = emptyMap(),
) {
    /** A listed day: its date, its figures and its uses, newest first. */
    data class ShownDay(val date: LocalDate, val counts: ActivityCounts, val rows: List<Use>)

    /** One use as a row: [key] names it in the list whatever comes before it, [time] is shown. */
    data class Use(val key: String, val time: String, val row: ActivityRow)

    /**
     * This page with the days, rows and cells that equal [old]'s taken from [old]: a screen
     * redraws only what changed (a new use redraws its row, not the hundreds already shown).
     */
    fun reusing(old: ActivityPage?): ActivityPage {
        if (old == null) return this
        val oldDays = old.days.associateBy { it }
        val oldRows = old.days.flatMap { it.rows }.associateBy { it }
        return ActivityPage(
            days.map { d -> oldDays[d] ?: d.copy(rows = d.rows.map { oldRows[it] ?: it }) },
            if (cells == old.cells) old.cells else cells,
            machines,
        )
    }

    companion object {
        /**
         * [grid] is the heatmap's, on the main tab; null for one machine's log. The rows of
         * [old] are kept for the uses it already had while the machines are the same: each new
         * row is a call into the shared core.
         */
        fun load(engine: Engine, machine: String?, today: LocalDate, zone: ZoneId, grid: HeatGrid?, old: ActivityPage? = null): ActivityPage {
            val days = safe { ActivityDays.load(engine.store, machine, today, zone) } ?: emptyList()
            // A row names its machine by its name, nickname and tag: the rest of the record (its
            // last status and when it was last seen above all) is left out, as each row passes it
            // through the FFI and the rows are kept while these stay the same.
            val machines = engine.liveMachines().associate {
                it.key to it.copy(
                    boxKey = "", os = "", model = null, hint = null, pairedAt = 0u, lastSeen = null, lastStatus = null,
                    flagged = false, relay = "", updated = 0u,
                )
            }
            val known = old?.takeIf { it.machines == machines }?.days?.flatMap { it.rows }?.associateBy { it.key } ?: emptyMap()
            val shown = days.map { d ->
                val seen = HashMap<String, Int>()
                ShownDay(d.date, d.counts, d.entries.map { e ->
                    // The same use reported twice in one millisecond still gets a key of its own.
                    val base = listOf(e.time, e.machine, e.key, e.outcome, e.agent, e.repo, e.command, e.kind).joinToString("|")
                    val key = "$base|${seen.merge(base, 1, Int::plus)}"
                    known[key] ?: Use(key, Texts.time(e.time.toLong()), activityRow(e, machines[e.machine]))
                })
            }
            val cells = grid?.let { g ->
                g.cells(safe { engine.store.dailyCounts(g.start.toString(), today.toString(), engine.offset()) } ?: emptyList())
            }
            return ActivityPage(shown, cells, machines)
        }
    }
}

/**
 * The heatmap's grid (SPEC.md 11.12): 53 weeks in columns, ending with the week of `today`,
 * each column starting on the locale's first day of the week. Days after today are left empty.
 */
class HeatGrid(val today: LocalDate, firstDay: DayOfWeek, val weeks: Int = WEEKS) {
    val start: LocalDate = today.with(TemporalAdjusters.previousOrSame(firstDay)).minusWeeks((weeks - 1).toLong())

    /** Every day from [start] to today, in grid order (column by column). */
    val days: List<LocalDate> = generateSequence(start) { it.plusDays(1) }.takeWhile { it <= today }.toList()

    fun date(week: Int, row: Int): LocalDate = start.plusDays(week * 7L + row)

    /** Day index in [days] of a cell, or null for a cell after today. */
    fun index(week: Int, row: Int): Int? = (week * 7 + row).takeIf { week in 0 until weeks && row in 0..6 && it < days.size }

    /** Columns where a month's label starts: where the month of the top cell changes. A first,
     * partial month is labelled only when its label has room before the next. */
    fun monthStarts(): List<Int> {
        val starts = (1 until weeks).filter { date(it, 0).month != date(it - 1, 0).month }
        return if (starts.isEmpty() || starts.first() >= 3) listOf(0) + starts else starts
    }

    /** Rows labelled on the side: Monday, Wednesday and Friday, as GitHub does. */
    fun labelledRows(): List<Int> = (0..6).filter { date(0, it).dayOfWeek in setOf(DayOfWeek.MONDAY, DayOfWeek.WEDNESDAY, DayOfWeek.FRIDAY) }

    /** Each day's counts (zero when nothing was counted) and heat level, in grid order. */
    fun cells(counts: List<DailyCount>): List<Cell> {
        val byDay = counts.associateBy { it.day }
        val used = days.map { byDay[it.toString()]?.used ?: 0uL }
        val levels = heatLevels(used)
        return days.mapIndexed { i, d ->
            val c = byDay[d.toString()]
            Cell(d, c?.used?.toLong() ?: 0L, c?.declined?.toLong() ?: 0L, levels[i].toInt())
        }
    }

    data class Cell(val date: LocalDate, val used: Long, val declined: Long, val level: Int)

    companion object {
        const val WEEKS = 53
    }
}
