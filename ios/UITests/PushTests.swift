import XCTest

/// SPEC.md 10.1, 16.3: pushes shaped like the relay's, delivered with `xcrun simctl push`,
/// which runs the Notification Service Extension. APNs itself needs a signed build.
final class PushTests: SealctlTestCase {
    override func setUpWithError() throws {
        try super.setUpWithError()
        try XCTSkipUnless(Env.fakeRelay, "uses the fake relay")
    }

    static func payload(type: String, id: String, expires: Int64) -> [String: Any] {
        [
            "aps": [
                "alert": ["title-loc-key": "REQUEST_TITLE", "loc-key": "REQUEST_BODY"],
                "mutable-content": 1,
                "category": "SEALCTL_REQUEST",
                "thread-id": "requests",
                "interruption-level": "time-sensitive",
            ],
            "type": type, "id": id, "expires": expires,
        ]
    }

    func testPushWhileInBackgroundShowsTheRequestAndOpensTheCard() {
        restoreVectorWords()
        pairFakeMachine()
        XCUIDevice.shared.press(.home)
        // The app closes its relay socket when it leaves the foreground (8.3), so the request
        // reaches it only as the push below. A socket open longer than 30 s used to outlive the
        // foreground and take the request into the background app (the relay logged "sent to 1
        // phone socket(s)"), which then opened it there and posted its own notification too.
        XCTAssertTrue(FakeRelay.untilPhoneSockets(0, timeout: 15), "the app's relay socket outlived its foreground")
        let job = Harness.machine("m1", ["request", "--kind", "open", "--subject", "secret:OPENAI_API_KEY", "--new-key",
                                         "secrets:store-1", "--cmd", "npm test", "--cwd", "~/dev/shop"])
        let id = job.find("sent \\S+ request (\\S+)", timeout: 20)!
        Harness.push(Self.payload(type: "request", id: id, expires: Int64(Date().timeIntervalSince1970 * 1000) + 300_000))

        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let rewritten = springboard.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS 'Allow OPENAI_API_KEY?'")).firstMatch
        let generic = springboard.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS 'Waiting for your phone'")).firstMatch
        let end = Date().addingTimeInterval(30)
        while !rewritten.exists && !generic.exists && Date() < end { Thread.sleep(forTimeInterval: 0.5) }
        guard rewritten.exists || generic.exists else {
            XCTFail("no notification\n\(uiTree(3000, of: springboard))")
            return
        }
        // The extension opens the request with the phone keys and rewrites the text (10.1);
        // without the app group and keychain sharing (an unsigned build) it can't, and the
        // relay's own text stays.
        let wasRewritten = rewritten.exists
        XCTContext.runActivity(named: wasRewritten ? "the request's own text (extension)" : "notification left as the relay sent it") { _ in }
        // Either notification opens this request: both carry its id.
        guard openFromNotification(springboard, titles: ["Allow OPENAI_API_KEY?", "Waiting for your phone"]) else { return }
        card("Allow OPENAI_API_KEY?", 30)
        tap("Allow once")
        // A failure carries the app's UI tree, so the run keeps its screenshot.
        XCTAssertEqual(job.wait(30).0, 0, uiTree(3000))
    }

    /// Opens the request from its notification: a tap on its banner when one stands still on
    /// screen, else a tap on its row in Notification Center, where it stays until it is handled.
    /// `titles` are the texts the request's notifications can have.
    ///
    /// A request could show two banners in a row. When the app's relay socket outlived its
    /// foreground, the request reached the background app and it posted its own notification
    /// ("Allow OPENAI_API_KEY?"); the pushed one followed a few seconds later (unsigned, the
    /// extension leaves the relay's "Waiting for your phone"). Each failed run (45281524313,
    /// 45276400487, 45315290307) logged the request "sent to 1 phone socket(s)". The socket now
    /// closes and the test checks it does; the banner handling below stays for any banner.
    ///
    /// - A banner is tapped by coordinate, and only when its frame is whole on screen and the
    ///   same in two reads: a banner sliding away can still report itself hittable, and an
    ///   element tap then fails the test outright (45315290307: "Failed to scroll to visible …
    ///   BannerNotification {{164.3, -103.3}, {73.3, 17.9}}", then "no matches found").
    /// - A drag from the top edge while any banner is up does not open Notification Center
    ///   (45281524313: "Interrupting element BannerNotification", then the home screen), so every
    ///   banner goes first. A drag counts when a row of the request, or a stack holding one,
    ///   shows; a stack is expanded. Otherwise the home button closes what the drag opened and
    ///   the drag is made again, up to three times.
    ///
    /// A tap that brings no foreground is tried again only while the app still runs (a banner
    /// that left under the tap): if the app is not running, it crashed, and the failure says so
    /// instead of a second tap hiding it. Failures carry springboard's UI tree (and so the
    /// screenshot is kept).
    private func openFromNotification(_ springboard: XCUIApplication, titles: [String],
                                      file: StaticString = #filePath, line: UInt = #line) -> Bool {
        let either = NSCompoundPredicate(orPredicateWithSubpredicates: titles.map { NSPredicate(format: "label CONTAINS %@", $0) })
        let more = NSPredicate(format: "label CONTAINS[c] 'more notification'")
        // A notification itself, and a stack's summary ("…, 2 more notifications").
        let row = springboard.descendants(matching: .any)
            .matching(NSCompoundPredicate(andPredicateWithSubpredicates: [either, NSCompoundPredicate(notPredicateWithSubpredicate: more)])).firstMatch
        let stack = springboard.descendants(matching: .any)
            .matching(NSCompoundPredicate(andPredicateWithSubpredicates: [either, more])).firstMatch
        // Any banner, this request's or another: the id XCTest reports for an interrupting banner.
        let banner = springboard.descendants(matching: .any).matching(identifier: "NotificationShortLookView").firstMatch
        let screen = springboard.windows.firstMatch.frame
        let deadline = Date().addingTimeInterval(90)
        // With Notification Center closed, the request's text shows only on a banner.
        func bannerUp() -> Bool { banner.exists || row.exists || stack.exists }
        func poll(until end: Date, while busy: () -> Bool) {
            while busy() && Date() < min(end, deadline) { Thread.sleep(forTimeInterval: 0.25) }
        }
        /// True when the tap brought the app to the foreground; false when it may have missed.
        func opened(_ via: String) -> Bool? {
            if app.wait(for: .runningForeground, timeout: 15) { return true }
            if app.state == .notRunning {
                XCTFail("the app is not running after the tap (\(via))\n\(uiTree(3000, of: springboard))", file: file, line: line)
                return nil
            }
            return false
        }

        // Banners: tap one of the request's as soon as it stands still on screen, until none is up.
        var missed = false
        while bannerUp() && Date() < deadline {
            if tapWhenStill(row, springboard, screen) {
                guard let ok = opened("banner") else { return false }
                if ok { return true }
                missed = true
                break
            }
            Thread.sleep(forTimeInterval: 0.25)
        }

        // Notification Center. From the top edge on the left half (the right half is Control Center).
        let top = springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.005))
        let down = springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.75))
        var drags = 0
        while drags < 3 && Date() < deadline {
            if drags > 0 || missed {
                // Closes what the last drag or a missed tap opened (Notification Center without
                // the row, a long look, search, another app).
                XCUIDevice.shared.press(.home)
                poll(until: Date().addingTimeInterval(10), while: bannerUp)
            }
            poll(until: Date().addingTimeInterval(20), while: bannerUp)
            top.press(forDuration: 0.1, thenDragTo: down)
            drags += 1
            poll(until: Date().addingTimeInterval(10)) { !row.exists && !stack.exists }
            if !row.exists && stack.exists {
                poll(until: Date().addingTimeInterval(10)) { !tapWhenStill(stack, springboard, screen) }
                poll(until: Date().addingTimeInterval(10)) { !row.exists }
            }
            var tapped = false
            poll(until: Date().addingTimeInterval(10)) {
                tapped = row.exists && tapWhenStill(row, springboard, screen)
                return !tapped
            }
            if tapped {
                guard let ok = opened("Notification Center") else { return false }
                if ok { return true }
            }
        }
        XCTFail("not opened from Notification Center after \(drags) drags: \(titles.joined(separator: " / "))\n\(uiTree(3000, of: springboard))",
                file: file, line: line)
        return false
    }

    /// Taps the middle of `e` by coordinate when its frame is whole on screen and the same in two
    /// reads 0.3 s apart. Reads go through snapshots, which fail softly when the element has gone,
    /// and a coordinate tap never fails the test: false when it was not tapped.
    private func tapWhenStill(_ e: XCUIElement, _ springboard: XCUIApplication, _ screen: CGRect) -> Bool {
        func frame() -> CGRect? {
            guard let f = try? e.snapshot().frame, !f.isEmpty, screen.contains(f) else { return nil }
            return f
        }
        guard let first = frame() else { return false }
        Thread.sleep(forTimeInterval: 0.3)
        guard let still = frame(), still == first else { return false }
        springboard.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: still.midX, dy: still.midY)).tap()
        return true
    }

    func testPushInTheForegroundShowsNoBannerButTheCard() {
        restoreVectorWords()
        pairFakeMachine()
        let job = Harness.machine("m1", ["request", "--kind", "own", "--subject", "secret:DEPLOY_TOKEN", "--new-key", "secret:own-1"])
        let id = job.find("sent \\S+ request (\\S+)", timeout: 20)!
        Harness.push(Self.payload(type: "request", id: id, expires: Int64(Date().timeIntervalSince1970 * 1000) + 300_000))
        card("Allow DEPLOY_TOKEN once?")
        tap("Deny")
        XCTAssertEqual(job.wait(30).0, 2)
    }
}
