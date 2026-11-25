import Foundation
import Testing
import EngineKit
import SealCore

/// The Activity screen's month titles, days and heatmap grid (SPEC.md 11.12).
struct ActivityDaysTests {
    @Test func monthTitlesAreStandaloneAndCapitalised() {
        // Inside a date Polish says "listopada"; on its own, as a title, "Listopad".
        #expect(Texts.monthTitle("2026-11", locale: Locale(identifier: "pl")) == "Listopad")
        #expect(Texts.monthTitle("2026-11", locale: Locale(identifier: "uk")) == "Листопад")
        #expect(Texts.monthTitle("2026-11", locale: Locale(identifier: "ru")) == "Ноябрь")
        #expect(Texts.monthTitle("2027-01", locale: Locale(identifier: "pl")) == "Styczeń")
        #expect(Texts.monthTitle("2026-11", locale: Locale(identifier: "en")) == "November")
        #expect(Texts.monthName(11, locale: Locale(identifier: "pl"), short: true).hasPrefix("Lis"))
    }

    @Test func summaryFiguresAreSingularForOne() {
        #expect(Texts.keysUsed(312, machines: 3) == "312 keys used on 3 machines")
        #expect(Texts.keysUsed(1, machines: 1) == "1 key used on 1 machine")
        #expect(Texts.keysUsed(0, machines: 0) == "0 keys used on 0 machines")
        #expect(Texts.keysUsed(2, machines: 1) == "2 keys used on 1 machine")
        #expect(Texts.requestsDeclined(1) == "1 request declined")
        #expect(Texts.requestsDeclined(4) == "4 requests declined")
        #expect(Texts.requestsDeclined(0) == "0 requests declined")
    }

    var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        c.locale = Locale(identifier: "pl")
        c.firstWeekday = 2
        return c
    }

    /// 2026-11-25 (a Wednesday) at `hour`, `days` before.
    func at(_ days: Int, _ hour: Int, _ outcome: String = "one_tap") -> UsageEntry {
        let today = calendar.date(from: DateComponents(year: 2026, month: 11, day: 25, hour: hour))!
        let t = calendar.date(byAdding: .day, value: -days, to: today)!
        return UsageEntry(time: UInt64(t.timeIntervalSince1970 * 1000), machine: "m", key: "K", agent: nil, repo: nil,
                          command: nil, outcome: outcome, kind: nil)
    }

    var today: Date { calendar.date(from: DateComponents(year: 2026, month: 11, day: 25, hour: 12))! }

    @Test func theNewestDayAndTheTenBeforeTodayAreListed() {
        let days = ActivityDays.group([at(0, 9), at(0, 8, "denied"), at(1, 22), at(10, 7), at(11, 7)], today: today, calendar: calendar)
        #expect(days.map(\.id) == ["2026-11-25", "2026-11-24", "2026-11-15"])
        #expect(days[0].counts == ActivityCounts(uses: 1, declined: 1))
        #expect(Texts.dayCounts(days[0].counts) == "1 use · 1 declined")
        #expect(Texts.dayCounts(ActivityCounts(uses: 37, declined: 0)) == "37 uses")
    }

    @Test func aNewestDayOlderThanTheWindowIsStillListed() {
        let days = ActivityDays.group([at(30, 9), at(40, 9)], today: today, calendar: calendar)
        #expect(days.map(\.id) == ["2026-10-26"])
        #expect(ActivityDays.group([], today: today, calendar: calendar).isEmpty)
        let since = ActivityDays.since(newest: at(30, 9), today: today, calendar: calendar)
        #expect(since == Int64(calendar.date(from: DateComponents(year: 2026, month: 10, day: 26))!.timeIntervalSince1970 * 1000))
    }

    @Test func theGridEndsWithTodaysWeekAndStartsOnTheFirstWeekday() {
        let monday = HeatGrid(today: today, calendar: calendar)
        #expect(HeatGrid.iso(monday.start, calendar) == "2025-11-24")
        #expect(monday.days.count == 52 * 7 + 3)
        #expect(HeatGrid.iso(monday.days.last!, calendar) == "2026-11-25")
        #expect(monday.labelledRows() == [0, 2, 4])
        #expect(monday.index(week: 52, row: 3) == nil)
        #expect(monday.index(week: 52, row: 2) == monday.days.count - 1)
        #expect(monday.monthStarts().count == 12)
        var us = calendar
        us.firstWeekday = 1
        let sunday = HeatGrid(today: today, calendar: us)
        #expect(us.component(.weekday, from: sunday.start) == 1)
        #expect(sunday.labelledRows() == [1, 3, 5])
    }

    @Test func cellsCarryTheCountsAndTheirLevels() {
        let grid = HeatGrid(today: today, calendar: calendar)
        let cells = grid.cells([DailyCount(day: "2026-11-25", used: 40, declined: 2), DailyCount(day: "2026-11-24", used: 1, declined: 0)])
        #expect(cells.count == grid.days.count)
        #expect(cells.last?.used == 40 && cells.last?.declined == 2 && cells.last?.level == 4)
        #expect(cells[cells.count - 2].level == 1)
        #expect(cells.first?.level == 0)
        #expect(Texts.heatTitle(1204, locale: Locale(identifier: "en_US")) == "1,204 key uses in the last year")
        #expect(Texts.heatDay(today, used: 1, declined: 2, locale: Locale(identifier: "en_US")).hasSuffix(": 1 key use, 2 declined"))
    }
}
