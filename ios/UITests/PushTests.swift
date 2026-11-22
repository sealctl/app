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
        XCTAssertTrue(rewritten.exists || generic.exists, "no notification:\n\(springboard.debugDescription.prefix(3000))")
        // The extension opens the request with the phone keys and rewrites the text (10.1);
        // without the app group and keychain sharing (an unsigned build) it can't, and the
        // relay's own text stays.
        let wasRewritten = rewritten.exists
        XCTContext.runActivity(named: wasRewritten ? "notification rewritten by the extension" : "notification left as the relay sent it") { _ in }
        // The banner is transient: on a slow runner it can go between finding it and tapping it.
        // Open the request from Notification Center, where it stays until it is handled.
        openFromNotificationCenter(label: wasRewritten ? "Allow OPENAI_API_KEY?" : "Waiting for your phone")
        card("Allow OPENAI_API_KEY?", 30)
        tap("Allow once")
        XCTAssertEqual(job.wait(30).0, 0)
    }

    /// Lets the banner go, swipes Notification Center down and taps the notification there.
    private func openFromNotificationCenter(label: String, file: StaticString = #filePath, line: UInt = #line) {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let match = NSPredicate(format: "label CONTAINS %@", label)
        let banner = springboard.descendants(matching: .any).matching(match).firstMatch
        let gone = Date().addingTimeInterval(15)
        while banner.exists && Date() < gone { Thread.sleep(forTimeInterval: 0.5) }
        // From the top edge on the left half: Notification Center (the right half is Control Center).
        let top = springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.005))
        top.press(forDuration: 0.1, thenDragTo: springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.75)))
        let cell = springboard.descendants(matching: .any).matching(match).firstMatch
        guard cell.waitForExistence(timeout: 20) else {
            XCTFail("not in Notification Center: \(label)\n\(springboard.debugDescription.prefix(3000))", file: file, line: line)
            return
        }
        cell.tap()
        // Earlier tests' notifications from this app can stack with this one: the first tap on
        // a stack expands it, the second opens the request.
        if !app.wait(for: .runningForeground, timeout: 5), cell.exists {
            cell.tap()
        }
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 15), "the app did not open from the notification",
                      file: file, line: line)
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
