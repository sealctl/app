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
        XCTContext.runActivity(named: rewritten.exists ? "notification rewritten by the extension" : "notification left as the relay sent it") { _ in }
        (rewritten.exists ? rewritten : generic).tap()
        card("Allow OPENAI_API_KEY?", 30)
        tap("Allow once")
        XCTAssertEqual(job.wait(30).0, 0)
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
