import Foundation
import SealCore

/// The days of the Activity log (SPEC.md 11.12): the newest day with entries, open, and the
/// days with entries among the ten before today, closed. Older days are not listed.
public enum ActivityDays {
    /// Calendar days before today that are listed.
    public static let daysBefore = 10

    public struct Day: Identifiable, Equatable {
        /// `YYYY-MM-DD`, local.
        public let id: String
        /// The day's first moment, local.
        public let date: Date
        /// Newest first.
        public let entries: [UsageEntry]
        public let counts: ActivityCounts
    }

    /// The first day the log reads from (Unix ms): ten days before today, or the newest
    /// entry's day when that is older.
    public static func since(newest: UsageEntry?, today: Date, calendar: Calendar) -> Int64 {
        var from = calendar.date(byAdding: .day, value: -daysBefore, to: calendar.startOfDay(for: today))!
        if let newest {
            let day = calendar.startOfDay(for: date(newest))
            if day < from { from = day }
        }
        return Int64(from.timeIntervalSince1970 * 1000)
    }

    /// `entries` (newest first) by local day: the newest day, and the days from ten before
    /// today on, newest first.
    public static func group(_ entries: [UsageEntry], today: Date, calendar: Calendar) -> [Day] {
        var order: [Date] = []
        var byDay: [Date: [UsageEntry]] = [:]
        for e in entries {
            let d = calendar.startOfDay(for: date(e))
            if byDay[d] == nil { order.append(d) }
            byDay[d, default: []].append(e)
        }
        guard let newest = order.max() else { return [] }
        let from = calendar.date(byAdding: .day, value: -daysBefore, to: calendar.startOfDay(for: today))!
        return order.filter { $0 >= from || $0 == newest }.sorted(by: >).map { d in
            let list = byDay[d] ?? []
            return Day(id: HeatGrid.iso(d, calendar), date: d, entries: list, counts: activityCounts(entries: list))
        }
    }

    static func date(_ e: UsageEntry) -> Date { Date(timeIntervalSince1970: Double(e.time) / 1000) }
}

/// The heatmap's grid (SPEC.md 11.12): 53 weeks in columns, ending with the week of today,
/// each column starting on the calendar's first day of the week. Days after today are empty.
public struct HeatGrid {
    public static let weeks = 53

    public struct Cell: Equatable {
        public let date: Date
        public let iso: String
        public let used: UInt64
        public let declined: UInt64
        public let level: Int
    }

    public let calendar: Calendar
    public let today: Date
    public let start: Date
    /// Every day from `start` to today, in grid order (column by column).
    public let days: [Date]

    public init(today: Date, calendar: Calendar) {
        self.calendar = calendar
        self.today = calendar.startOfDay(for: today)
        let back = (calendar.component(.weekday, from: self.today) - calendar.firstWeekday + 7) % 7
        start = calendar.date(byAdding: .day, value: -back - 7 * (Self.weeks - 1), to: self.today)!
        var days: [Date] = []
        var d = start
        while d <= self.today {
            days.append(d)
            d = calendar.date(byAdding: .day, value: 1, to: d)!
        }
        self.days = days
    }

    public func date(week: Int, row: Int) -> Date {
        calendar.date(byAdding: .day, value: week * 7 + row, to: start)!
    }

    /// The day index in `days` of a cell, or nil for a cell after today.
    public func index(week: Int, row: Int) -> Int? {
        let i = week * 7 + row
        return (0..<Self.weeks).contains(week) && (0...6).contains(row) && i < days.count ? i : nil
    }

    /// Columns where a month's label starts: where the month of the top cell changes. A first,
    /// partial month is labelled only when its label has room before the next.
    public func monthStarts() -> [Int] {
        let month = { (w: Int) in calendar.component(.month, from: date(week: w, row: 0)) }
        let starts = (1..<Self.weeks).filter { month($0) != month($0 - 1) }
        if let first = starts.first, first < 3 { return starts }
        return [0] + starts
    }

    /// Rows labelled at the side: Monday, Wednesday and Friday, as GitHub does.
    public func labelledRows() -> [Int] {
        (0...6).filter { [2, 4, 6].contains(calendar.component(.weekday, from: date(week: 0, row: $0))) }
    }

    /// Each day's counts (zero when nothing was counted) and heat level, in grid order.
    public func cells(_ counts: [DailyCount]) -> [Cell] {
        let byDay = Dictionary(counts.map { ($0.day, $0) }, uniquingKeysWith: { a, _ in a })
        let isos = days.map { Self.iso($0, calendar) }
        let levels = heatLevels(counts: isos.map { byDay[$0]?.used ?? 0 })
        return days.indices.map { i in
            let c = byDay[isos[i]]
            return Cell(date: days[i], iso: isos[i], used: c?.used ?? 0, declined: c?.declined ?? 0, level: Int(levels[i]))
        }
    }

    /// `YYYY-MM-DD` of a local day.
    public static func iso(_ d: Date, _ calendar: Calendar) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: d)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }
}
