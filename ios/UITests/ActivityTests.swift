import XCTest

/// SPEC.md 16.4 item 12 and 11.12: the Activity log by day (the newest open, earlier days closed
/// until tapped) and the heatmap of the last year under it, from uses the fake machine reports.
final class ActivityTests: SealctlTestCase {
    override func setUpWithError() throws {
        try super.setUpWithError()
        try XCTSkipUnless(Env.fakeRelay, "uses the fake relay")
    }

    /// `YYYY-MM-DD` of the day `days` before today, local.
    func day(_ days: Int) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: Calendar.current.date(byAdding: .day, value: -days, to: Date())!)
    }

    /// Scrolls the page until `e` is on screen.
    func reveal(_ e: XCUIElement, file: StaticString = #filePath, line: UInt = #line) {
        for _ in 0..<8 where !e.isHittable { app.swipeUp() }
        XCTAssertTrue(e.isHittable, "not on screen: \(e.identifier)\n\(uiTree())", file: file, line: line)
    }

    func testDaysOpenAndCloseAndTheHeatmapIsBelow() {
        restoreVectorWords()
        pairFakeMachine()
        // Two uses made two days ago (reported late), and one now.
        XCTAssertEqual(Harness.machine("m1", ["status", "--state", "open", "--left", "7200",
                                              "--log", "env:shop/EARLIER_KEY", "--log", "env:shop/EARLIER_KEY",
                                              "--log-ago", "\(2 * 86_400)"]).wait(20).0, 0)
        XCTAssertEqual(Harness.machine("m1", ["status", "--state", "open", "--left", "7200",
                                              "--log", "env:shop/TODAY_KEY"]).wait(20).0, 0)
        tab("Activity")
        // Today is open.
        see("TODAY_KEY", 30)
        XCTAssertTrue(element("day \(day(0))").exists)
        // Two days ago is one closed header with its count.
        let earlier = element("day \(day(2))")
        XCTAssertTrue(earlier.waitForExistence(timeout: 15), uiTree())
        XCTAssertTrue(earlier.label.contains("2 uses"), earlier.label)
        XCTAssertEqual(earlier.value as? String, "Collapsed")
        XCTAssertFalse(shows("EARLIER_KEY", 1))
        reveal(earlier)
        earlier.tap()
        see("EARLIER_KEY")
        XCTAssertEqual(element("day \(day(2))").value as? String, "Expanded")
        element("day \(day(2))").tap()
        gone(text("EARLIER_KEY"))

        // The heatmap: the report reached the phone today, so its three uses count today.
        let map = element("heatmap")
        reveal(map)
        XCTAssertTrue(map.label.hasPrefix("3 key uses in the last year"), map.label)
        see("3 key uses in the last year")
        // A tap on today's cell (the grid opens at today, on the right) shows its figures.
        map.coordinate(withNormalizedOffset: CGVector(dx: 52.5 / 53, dy: (CGFloat(weekdayRow()) + 0.5) / 7)).tap()
        let picked = element("heatmap day")
        XCTAssertTrue(picked.label.hasSuffix(": 3 key uses"), picked.label)
    }

    /// Waits until the element is no longer shown.
    func gone(_ e: XCUIElement, file: StaticString = #filePath, line: UInt = #line) {
        let left = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: e)
        XCTAssertEqual(XCTWaiter.wait(for: [left], timeout: 10), .completed, "still shown\n\(uiTree())", file: file, line: line)
    }

    /// Today's row in the grid: days since the calendar's first weekday.
    func weekdayRow() -> Int {
        let c = Calendar.current
        return (c.component(.weekday, from: Date()) - c.firstWeekday + 7) % 7
    }
}
