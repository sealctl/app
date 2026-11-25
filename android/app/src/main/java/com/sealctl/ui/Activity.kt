package com.sealctl.ui

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.layout.wrapContentHeight
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.KeyboardArrowDown
import androidx.compose.material.icons.filled.KeyboardArrowUp
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateMapOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.CustomAccessibilityAction
import androidx.compose.ui.semantics.LiveRegionMode
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.customActions
import androidx.compose.ui.semantics.liveRegion
import androidx.compose.ui.semantics.role
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.sealctl.app.ActivityDays
import com.sealctl.app.Graph
import com.sealctl.app.HeatGrid
import com.sealctl.app.Route
import com.sealctl.app.Texts
import com.sealctl.app.Ui
import com.sealctl.core.app.ActivityRow
import com.sealctl.core.app.ActivityTone
import com.sealctl.core.app.MonthSummary
import com.sealctl.core.app.activityRow
import com.sealctl.designsystem.Muted
import com.sealctl.designsystem.Sealctl
import com.sealctl.designsystem.SurfaceCard
import java.time.LocalDate
import java.time.ZoneId
import java.time.format.TextStyle as DateTextStyle
import java.time.temporal.WeekFields
import java.util.Locale

/**
 * Activity (SPEC.md 11.12): the month's summary, hand-back reports, the newest day open and the
 * ten days before today closed, and, on the main tab, the heatmap of the last year.
 */
@Composable
fun ActivityList(machine: String?) {
    val engine = Graph.engine
    val state by engine.state.collectAsState()
    val locale = LocalConfiguration.current.locales[0]
    val zone = ZoneId.systemDefault()
    val today = LocalDate.now(zone)
    val days = remember(state, machine, today) {
        com.sealctl.app.safe { ActivityDays.load(engine.store, machine, today, zone) } ?: emptyList()
    }
    // Which days the person opened or closed; in memory only. The newest day starts open.
    val toggled = remember(machine) { mutableStateMapOf<LocalDate, Boolean>() }

    SummaryCard(state.summaries, Texts.isoDate(System.currentTimeMillis()).take(7), locale)
    for (r in state.reports.sortedByDescending { it.time }.take(5)) {
        SurfaceCard(Modifier.clickable { Ui.push(Route.Report(r.id)) }) {
            Text("${r.machineName} handed everything back", fontWeight = FontWeight.SemiBold, color = Sealctl.colors.ink)
            Muted("${r.items.count { it.state == "done" }} of ${r.items.size} done · ${Texts.mediumDate(r.time.toLong())}")
        }
    }
    if (days.isEmpty()) {
        Muted("Nothing yet. Every use of your keys shows here.")
    }
    for ((i, day) in days.withIndex()) {
        val open = toggled[day.date] ?: (i == 0)
        DayHeader(Texts.mediumDate(day.date, locale), Texts.dayCounts(day.counts), day.date.toString(), open) { toggled[day.date] = !open }
        if (open) {
            val rows = remember(day.entries, state) { day.entries.map { e -> Texts.time(e.time.toLong()) to activityRow(e, engine.machine(e.machine)) } }
            Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                for ((time, row) in rows) ActivityLine(time, row)
            }
        }
    }
    // The counts are the phone's, not a machine's: the heatmap shows on the main tab only.
    if (machine == null) {
        val grid = remember(today, locale) { HeatGrid(today, WeekFields.of(locale).firstDayOfWeek) }
        val cells = remember(state, grid) {
            val counts = com.sealctl.app.safe { engine.store.dailyCounts(grid.start.toString(), today.toString(), engine.offset()) } ?: emptyList()
            grid.cells(counts)
        }
        Heatmap(grid, cells, locale)
    }
}

/** This month's figures, with the previous months behind a chevron. */
@Composable
private fun SummaryCard(summaries: List<MonthSummary>, month: String, locale: Locale) {
    var showMonths by remember { mutableStateOf(false) }
    val older = summaries.filter { it.month != month }.sortedByDescending { it.month }
    SurfaceCard {
        MonthFigures(month, summaries.firstOrNull { it.month == month }, locale)
        if (older.isNotEmpty()) {
            Box(
                Modifier.fillMaxWidth().heightIn(min = 40.dp).clickable(role = Role.Button) { showMonths = !showMonths }
                    .semantics { contentDescription = "Previous months"; stateDescription = if (showMonths) "Shown" else "Hidden" },
                contentAlignment = Alignment.Center,
            ) {
                Icon(if (showMonths) Icons.Filled.KeyboardArrowUp else Icons.Filled.KeyboardArrowDown, contentDescription = null, tint = Sealctl.colors.ink2)
            }
            if (showMonths) for (s in older) MonthFigures(s.month, s, locale)
        }
    }
}

@Composable
private fun MonthFigures(month: String, s: MonthSummary?, locale: Locale) {
    Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
        Text(Texts.monthTitle(month, locale), fontWeight = FontWeight.SemiBold, color = Sealctl.colors.ink, fontSize = 18.sp)
        Text(Texts.keysUsed(s?.keysUsed?.toLong() ?: 0L, s?.machines?.size ?: 0), color = Sealctl.colors.ink2)
        Text(Texts.requestsDeclined(s?.requestsDeclined?.toLong() ?: 0L), color = Sealctl.colors.ink2)
        Muted("No key was written to disk.")
    }
}

/** One day's header: its date, its figures and a chevron; a tap opens or closes the day. */
@Composable
private fun DayHeader(date: String, counts: String, iso: String, open: Boolean, onToggle: () -> Unit) {
    val c = Sealctl.colors
    Row(
        Modifier.fillMaxWidth().heightIn(min = 48.dp).clickable(role = Role.Button, onClick = onToggle).testTag("day $iso")
            .clearAndSetSemantics {
                contentDescription = "$date, ${counts.replace(" · ", ", ")}"
                stateDescription = if (open) "Expanded" else "Collapsed"
                role = Role.Button
            },
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text(date, Modifier.weight(1f), color = c.ink, fontSize = 15.sp, fontWeight = FontWeight.SemiBold)
        Text(counts, Modifier.padding(horizontal = 8.dp), color = c.ink2, fontSize = 14.sp, style = TextStyle(fontFeatureSettings = "tnum"))
        Icon(if (open) Icons.Filled.KeyboardArrowUp else Icons.Filled.KeyboardArrowDown, contentDescription = null, tint = c.ink2)
    }
}

/** One use (11.12): the time, what was used and the outcome, then the details in muted text. */
@Composable
fun ActivityLine(time: String, row: ActivityRow) {
    val c = Sealctl.colors
    Row(Modifier.fillMaxWidth().clearAndSetSemantics { contentDescription = Texts.activityLabel(time, row) }) {
        Text(time, Modifier.alignByBaseline().widthIn(min = 44.dp).padding(end = 8.dp), color = c.ink2, fontSize = 14.sp, style = TextStyle(fontFeatureSettings = "tnum"))
        Column(Modifier.weight(1f).alignByBaseline()) {
            Row {
                Text(row.subject, Modifier.weight(1f).alignByBaseline(), color = c.ink, fontSize = 15.sp)
                Text(
                    row.outcome,
                    Modifier.padding(start = 8.dp).alignByBaseline(),
                    color = when (row.tone) { ActivityTone.DECLINED -> c.accent; ActivityTone.MUTED -> c.muted; ActivityTone.NORMAL -> c.ink2 },
                    fontSize = 14.sp,
                )
            }
            if (row.details.isNotEmpty()) Text(Texts.activityDetails(row), color = c.muted, fontSize = 13.sp)
        }
    }
}

private val CELL = 12.dp
private val GAP = 3.dp
private val STEP = CELL + GAP

/**
 * The last 53 weeks, one cell a day, coloured by its key uses (SPEC.md 11.12). It scrolls
 * sideways and opens at today, on the right. A tap shows the day's figures under it. For
 * TalkBack it is one element: a summary, the chosen day, and actions to move day by day or
 * week by week.
 */
@Composable
private fun Heatmap(grid: HeatGrid, cells: List<HeatGrid.Cell>, locale: Locale) {
    val c = Sealctl.colors
    var selected by remember(grid) { mutableStateOf<Int?>(null) }
    val total = cells.sumOf { it.used }
    val title = Texts.heatTitle(total, locale)
    val busiest = cells.maxByOrNull { it.used }?.takeIf { it.used > 0 }
    val summary = listOfNotNull(title, busiest?.let { "busiest day ${Texts.heatDay(it.date, it.used, it.declined, locale)}" }).joinToString(", ")
    val detail = selected?.let { cells.getOrNull(it) }?.let { Texts.heatDay(it.date, it.used, it.declined, locale) }
    fun move(by: Int): Boolean {
        val from = selected ?: cells.lastIndex
        selected = (from + by).coerceIn(0, cells.lastIndex)
        return true
    }
    val density = LocalDensity.current
    val stepPx = with(density) { STEP.toPx() }

    SurfaceCard(Modifier.testTag("heatmap")) {
        Text(title, fontWeight = FontWeight.SemiBold, color = c.ink, fontSize = 15.sp)
        Row {
            // Mon / Wed / Fri beside their rows, outside the part that scrolls.
            Box(Modifier.padding(top = 18.dp).width(32.dp).height(STEP * 7).clearAndSetSemantics {}) {
                for (row in grid.labelledRows()) {
                    Box(Modifier.offset(y = STEP * row).height(CELL), contentAlignment = Alignment.CenterStart) {
                        Text(
                            grid.date(0, row).dayOfWeek.getDisplayName(DateTextStyle.SHORT_STANDALONE, locale).replaceFirstChar { it.titlecase(locale) },
                            Modifier.wrapContentHeight(Alignment.CenterVertically, unbounded = true),
                            color = c.muted, fontSize = 10.sp, maxLines = 1, softWrap = false,
                        )
                    }
                }
            }
            Column(Modifier.horizontalScroll(rememberScrollState(), reverseScrolling = true)) {
                Box(Modifier.width(STEP * grid.weeks).height(18.dp).clearAndSetSemantics {}) {
                    for (w in grid.monthStarts()) {
                        Text(
                            Texts.monthName(grid.date(w, 0).month, locale, DateTextStyle.SHORT_STANDALONE),
                            Modifier.offset(x = STEP * w), color = c.muted, fontSize = 10.sp, maxLines = 1,
                        )
                    }
                }
                Canvas(
                    Modifier.size(STEP * grid.weeks, STEP * 7)
                        .pointerInput(grid, cells) {
                            detectTapGestures { p ->
                                val i = grid.index((p.x / stepPx).toInt(), (p.y / stepPx).toInt())
                                if (i != null) selected = if (selected == i) null else i
                            }
                        }
                        .semantics {
                            contentDescription = summary
                            detail?.let { stateDescription = it }
                            customActions = listOf(
                                CustomAccessibilityAction("Previous day") { move(-1) },
                                CustomAccessibilityAction("Next day") { move(1) },
                                CustomAccessibilityAction("Previous week") { move(-7) },
                                CustomAccessibilityAction("Next week") { move(7) },
                            )
                        },
                ) {
                    val cell = CELL.toPx()
                    val radius = CornerRadius(2.dp.toPx())
                    for ((i, d) in cells.withIndex()) {
                        val topLeft = Offset((i / 7) * stepPx, (i % 7) * stepPx)
                        drawRoundRect(c.heat[d.level.coerceIn(0, 4)], topLeft, Size(cell, cell), radius)
                        if (i == selected) drawRoundRect(c.ink, topLeft, Size(cell, cell), radius, style = Stroke(1.5.dp.toPx()))
                    }
                }
            }
        }
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text(
                detail ?: "",
                Modifier.weight(1f).semantics { liveRegion = LiveRegionMode.Polite }.testTag("heatmap day"),
                color = c.ink2, fontSize = 13.sp,
            )
            Row(Modifier.clearAndSetSemantics {}, verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(3.dp)) {
                Text("Less", color = c.muted, fontSize = 11.sp)
                for (color in c.heat) Spacer(Modifier.size(CELL).background(color, RoundedCornerShape(2.dp)))
                Text("More", color = c.muted, fontSize = 11.sp)
            }
        }
    }
}
