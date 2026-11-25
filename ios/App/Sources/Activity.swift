import DesignSystem
import Engine
import EngineKit
import SealCore
import SwiftUI

// MARK: Activity (11.12)

/// The month's summary, hand-back reports, the newest day open and the ten days before today
/// closed, and, on the main tab, the heatmap of the last year.
struct ActivityList: View {
    @Environment(AppModel.self) private var model
    @Environment(Router.self) private var router
    let machine: String?
    @SwiftUI.State private var days: [ActivityDays.Day] = []
    /// Days the person opened or closed; in memory only. The newest day starts open.
    @SwiftUI.State private var toggled: [String: Bool] = [:]
    @SwiftUI.State private var showMonths = false
    @SwiftUI.State private var grid = HeatGrid(today: Date(), calendar: .current)
    @SwiftUI.State private var cells: [HeatGrid.Cell] = []

    var body: some View {
        let e = model.engine!
        let month = String(Texts.isoDate(nowMs()).prefix(7))
        let summaries = e.state.summaries.sorted { $0.month > $1.month }
        let current = summaries.first { $0.month == month }
        Group {
            SurfaceCard {
                summary(month, current)
                if summaries.contains(where: { $0.month != month }) {
                    Button { showMonths.toggle() } label: {
                        Image(systemName: showMonths ? "chevron.up" : "chevron.down").frame(maxWidth: .infinity, minHeight: 32)
                    }
                    .accessibilityLabel("Previous months")
                }
                if showMonths {
                    ForEach(summaries.filter { $0.month != month }, id: \.month) { s in summary(s.month, s) }
                }
            }
            ForEach(e.state.reports.sorted { $0.time > $1.time }.prefix(5), id: \.id) { r in
                Button { router.push(.report(r.id)) } label: {
                    SurfaceCard {
                        Text(verbatim: r.what == "leave" ? "This phone left sealctl" : "\(shown(r.machineName)) handed everything back")
                            .fontWeight(.semibold).foregroundStyle(Palette.ink)
                        MutedText("\(r.items.filter { $0.state == "done" }.count) of \(r.items.count) done · \(Texts.mediumDate(Int64(r.time)))")
                    }
                }
                .buttonStyle(.plain)
            }
            if days.isEmpty {
                MutedText("Nothing yet. Every use of your keys shows here.")
            }
            ForEach(Array(days.enumerated()), id: \.element.id) { i, day in
                let open = toggled[day.id] ?? (i == 0)
                DayHeader(day: day, open: open) { toggled[day.id] = !open }
                if open {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(Array(day.entries.enumerated()), id: \.offset) { _, u in
                            ActivityLine(time: Texts.time(Int64(u.time)), row: activityRow(entry: u, machine: e.machine(u.machine)))
                        }
                    }
                }
            }
            // The counts are the phone's, not a machine's: the heatmap shows on the main tab only.
            if machine == nil {
                Heatmap(grid: grid, cells: cells)
            }
        }
        .task(id: e.state) {
            days = await e.activityDays(machine: machine)
            if machine == nil {
                let g = HeatGrid(today: Date(), calendar: .current)
                cells = await e.heatCells(g)
                grid = g
            }
        }
    }

    private func summary(_ month: String, _ s: MonthSummary?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(verbatim: Texts.monthTitle(month)).font(.headline).foregroundStyle(Palette.ink)
            Text(verbatim: Texts.keysUsed(s?.keysUsed ?? 0, machines: s?.machines.count ?? 0)).foregroundStyle(Palette.ink2)
            Text(verbatim: Texts.requestsDeclined(s?.requestsDeclined ?? 0)).foregroundStyle(Palette.ink2)
            MutedText("No key was written to disk.")
        }
    }
}

/// One day's header: its date, its figures and a chevron; a tap opens or closes the day.
struct DayHeader: View {
    let day: ActivityDays.Day
    let open: Bool
    let toggle: () -> Void

    var body: some View {
        let date = Texts.mediumDate(day.date, locale: .current)
        let counts = Texts.dayCounts(day.counts)
        Button(action: toggle) {
            HStack(spacing: 8) {
                Text(verbatim: date).fontWeight(.semibold).foregroundStyle(Palette.ink)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(verbatim: counts).font(.subheadline).monospacedDigit().foregroundStyle(Palette.ink2)
                Image(systemName: open ? "chevron.up" : "chevron.down").font(.subheadline).foregroundStyle(Palette.ink2)
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: "\(date), \(counts.replacingOccurrences(of: " · ", with: ", "))"))
        .accessibilityValue(open ? "Expanded" : "Collapsed")
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("day \(day.id)")
    }
}

/// One use (11.12): the time, what was used and the outcome, then the details in muted text.
struct ActivityLine: View {
    let time: String
    let row: ActivityRow
    @ScaledMetric(relativeTo: .subheadline) private var timeWidth: CGFloat = 52

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            Text(verbatim: time).font(.subheadline).monospacedDigit().foregroundStyle(Palette.ink2)
                .frame(width: timeWidth, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(verbatim: row.subject).foregroundStyle(Palette.ink)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text(verbatim: row.outcome).font(.subheadline).foregroundStyle(tone)
                }
                if !row.details.isEmpty {
                    Text(verbatim: Texts.activityDetails(row)).font(.footnote).foregroundStyle(Palette.muted)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: Texts.activityLabel(time, row)))
    }

    private var tone: Color {
        switch row.tone {
        case .declined: Palette.accent
        case .muted: Palette.muted
        case .normal: Palette.ink2
        }
    }
}

/// The last 53 weeks, one cell a day, coloured by its key uses (SPEC.md 11.12). It scrolls
/// sideways and opens at today, on the right. A tap shows the day's figures under it. For
/// VoiceOver it is one element: a summary, the chosen day as its value, swipe up or down to
/// move a day, and actions to move a week.
struct Heatmap: View {
    let grid: HeatGrid
    let cells: [HeatGrid.Cell]
    @SwiftUI.State private var selected: Int?
    private let cell: CGFloat = 12
    private let step: CGFloat = 15

    var body: some View {
        let total = cells.reduce(UInt64(0)) { $0 + $1.used }
        let title = Texts.heatTitle(total)
        let busiest = cells.max { $0.used < $1.used }.flatMap { $0.used > 0 ? $0 : nil }
        let summary = [title, busiest.map { "busiest day " + Texts.heatDay($0.date, used: $0.used, declined: $0.declined) }]
            .compactMap { $0 }.joined(separator: ", ")
        let detail = selected.flatMap { cells.indices.contains($0) ? cells[$0] : nil }
            .map { Texts.heatDay($0.date, used: $0.used, declined: $0.declined) }
        SurfaceCard {
            Text(verbatim: title).font(.subheadline.weight(.semibold)).foregroundStyle(Palette.ink)
                .accessibilityIdentifier("heatmap title")
            HStack(alignment: .top, spacing: 4) {
                weekdays
                ScrollView(.horizontal, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 4) {
                        months
                        canvas
                            .accessibilityElement()
                            .accessibilityLabel(Text(verbatim: summary))
                            .accessibilityValue(Text(verbatim: detail ?? ""))
                            .accessibilityAdjustableAction { d in
                                switch d {
                                case .increment: move(1)
                                case .decrement: move(-1)
                                @unknown default: break
                                }
                            }
                            .accessibilityAction(named: "Previous week") { move(-7) }
                            .accessibilityAction(named: "Next week") { move(7) }
                            .accessibilityIdentifier("heatmap")
                    }
                }
                .defaultScrollAnchor(.trailing)
            }
            HStack(spacing: 3) {
                Text(verbatim: detail ?? " ").font(.footnote).foregroundStyle(Palette.ink2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("heatmap day")
                Group {
                    Text("Less").font(.caption2).foregroundStyle(Palette.muted)
                    ForEach(0..<5, id: \.self) { l in
                        RoundedRectangle(cornerRadius: 2).fill(Palette.heat[l]).frame(width: cell, height: cell)
                    }
                    Text("More").font(.caption2).foregroundStyle(Palette.muted)
                }
                .accessibilityHidden(true)
            }
        }
    }

    /// Mon, Wed, Fri beside their rows, outside the part that scrolls.
    private var weekdays: some View {
        let names = grid.calendar.shortStandaloneWeekdaySymbols
        return ZStack(alignment: .topLeading) {
            ForEach(grid.labelledRows(), id: \.self) { r in
                let wd = grid.calendar.component(.weekday, from: grid.date(week: 0, row: r))
                Text(verbatim: names[wd - 1]).font(.system(size: 10)).foregroundStyle(Palette.muted).lineLimit(1)
                    .offset(y: CGFloat(r) * step - 1)
            }
        }
        .frame(width: 30, height: step * 7, alignment: .topLeading)
        .padding(.top, 16)
        .accessibilityHidden(true)
    }

    private var months: some View {
        ZStack(alignment: .topLeading) {
            ForEach(grid.monthStarts(), id: \.self) { w in
                let m = grid.calendar.component(.month, from: grid.date(week: w, row: 0))
                Text(verbatim: Texts.monthName(m, short: true)).font(.system(size: 10)).foregroundStyle(Palette.muted).lineLimit(1)
                    .fixedSize()
                    .offset(x: CGFloat(w) * step)
            }
        }
        .frame(width: step * CGFloat(HeatGrid.weeks), height: 12, alignment: .topLeading)
        .accessibilityHidden(true)
    }

    private var canvas: some View {
        Canvas { ctx, _ in
            for (i, c) in cells.enumerated() {
                let rect = CGRect(x: CGFloat(i / 7) * step, y: CGFloat(i % 7) * step, width: cell, height: cell)
                let path = Path(roundedRect: rect, cornerRadius: 2)
                ctx.fill(path, with: .color(Palette.heat[min(max(c.level, 0), 4)]))
                if i == selected { ctx.stroke(path, with: .color(Palette.ink), lineWidth: 1.5) }
            }
        }
        .frame(width: step * CGFloat(HeatGrid.weeks), height: step * 7)
        .contentShape(Rectangle())
        .onTapGesture { p in
            guard let i = grid.index(week: Int(p.x / step), row: Int(p.y / step)), i < cells.count else { return }
            selected = selected == i ? nil : i
        }
    }

    private func move(_ by: Int) {
        guard !cells.isEmpty else { return }
        selected = min(max((selected ?? cells.count - 1) + by, 0), cells.count - 1)
    }
}
