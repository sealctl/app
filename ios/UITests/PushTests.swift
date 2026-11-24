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
        Thread.sleep(forTimeInterval: 2)
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
        // relay's own text stays. The request's own text also shows when the app, not yet
        // suspended, got the request over its socket and posted the notification itself.
        let wasRewritten = rewritten.exists
        XCTContext.runActivity(named: wasRewritten ? "the request's own text (extension or app)" : "notification left as the relay sent it") { _ in }
        guard openFromNotification(springboard, title: wasRewritten ? "Allow OPENAI_API_KEY?" : "Waiting for your phone") else { return }
        card("Allow OPENAI_API_KEY?", 30)
        tap("Allow once")
        XCTAssertEqual(job.wait(30).0, 0)
    }

    /// Opens the request from its notification: one tap on the banner if it can be tapped, else
    /// one tap on its row in Notification Center, where it stays until it is handled.
    ///
    /// A request can show two banners in a row. When the app's relay socket is still open a moment
    /// after it went to the background, the request reaches it there and the app posts its own
    /// notification ("Allow OPENAI_API_KEY?"); the pushed one follows a few seconds later
    /// (unsigned, the extension leaves the relay's "Waiting for your phone"). In both failed
    /// runs (45281524313, 45276400487) the fake relay logged the request "sent to 1 phone
    /// socket(s)"; in passing runs, 0. While one banner replaces the other, neither can be
    /// tapped, and a drag from the top edge while a banner is up does not open Notification
    /// Center (XCTest logged "Interrupting element BannerNotification … NotificationShortLookView"
    /// and the tree after the drag was the home screen). So the banner is tapped whenever it can
    /// be, any banner is let go before the drag, and the drag counts only when the row shows; it
    /// is made again, after the home button closes whatever it opened, up to three times.
    ///
    /// The notification itself is tapped once only: if the app is not in the foreground after
    /// it, the failure carries springboard's UI tree (and so its screenshot is kept), and a
    /// crash after the tap is not hidden by a second one.
    private func openFromNotification(_ springboard: XCUIApplication, title: String,
                                      file: StaticString = #filePath, line: UInt = #line) -> Bool {
        // The notification itself, not a stack's summary ("…, 2 more notifications").
        let match = NSPredicate(format: "label CONTAINS %@ AND NOT (label CONTAINS[c] 'more notification')", title)
        let notification = springboard.descendants(matching: .any).matching(match).firstMatch
        // Any banner, this request's or another: the id XCTest reports for an interrupting banner.
        let banner = springboard.descendants(matching: .any).matching(identifier: "NotificationShortLookView").firstMatch
        let deadline = Date().addingTimeInterval(60)
        // With Notification Center closed, the notification's text shows only on a banner.
        func bannerUp() -> Bool { banner.exists || notification.exists }

        // Banners: tap this one as soon as it can be tapped, until none is up.
        var via = "banner"
        var tapped = false
        while bannerUp() && Date() < deadline {
            if notification.exists && notification.isHittable {
                notification.tap()
                tapped = true
                break
            }
            Thread.sleep(forTimeInterval: 0.25)
        }

        if !tapped {
            via = "Notification Center"
            // From the top edge on the left half: Notification Center (the right half is Control Center).
            let top = springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.005))
            let down = springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.75))
            var drags = 0
            var shown = false
            while !shown && drags < 3 && Date() < deadline {
                if drags > 0 {
                    // Closes what the last drag opened (Notification Center without the row, a
                    // banner's long look, search); then any new banner goes before the next drag.
                    XCUIDevice.shared.press(.home)
                    let closed = Date().addingTimeInterval(10)
                    while bannerUp() && Date() < closed { Thread.sleep(forTimeInterval: 0.25) }
                }
                let quiet = min(deadline, Date().addingTimeInterval(20))
                while bannerUp() && Date() < quiet { Thread.sleep(forTimeInterval: 0.25) }
                top.press(forDuration: 0.1, thenDragTo: down)
                drags += 1
                shown = notification.waitForExistence(timeout: 10)
            }
            guard shown else {
                XCTFail("not in Notification Center after \(drags) drags: \(title)\n\(uiTree(3000, of: springboard))",
                        file: file, line: line)
                return false
            }
            waitHittable(notification, 5)
            notification.tap()
        }
        guard app.wait(for: .runningForeground, timeout: 15) else {
            XCTFail("the app did not open from the notification (\(via))\n\(uiTree(3000, of: springboard))",
                    file: file, line: line)
            return false
        }
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
