import XCTest

/// SPEC.md 16.4 item 4 and 6: each request kind on the card; allow, allow once, deny,
/// remember; expired while open; several waiting; Answers; the activity log and inventory.
final class ApprovalTests: SealctlTestCase {
    override func setUpWithError() throws {
        try super.setUpWithError()
        try XCTSkipUnless(Env.fakeRelay, "uses the fake relay")
    }

    func testEveryLevelOneKind() {
        restoreVectorWords()
        pairFakeMachine()

        // open: Allow for this session.
        var job = Harness.machine("m1", ["request", "--kind", "open", "--subject", "secret:OPENAI_API_KEY", "--new-key",
                                         "secrets:store-1", "--cmd", "npm test", "--cwd", "~/dev/shop", "--agent", "claude"])
        card("Allow OPENAI_API_KEY?")
        see("npm test")
        see("~/dev/shop")
        see("dev@mbp.example.com · claude")
        tap("Allow for this session")
        XCTAssertEqual(job.wait(30).0, 0)

        // own: Allow once.
        job = Harness.machine("m1", ["request", "--kind", "own", "--subject", "secret:DEPLOY_TOKEN", "--new-key", "secret:own-1",
                                     "--cmd", "./deploy.sh"])
        card("Allow DEPLOY_TOKEN once?")
        see("This key asks every time. It stays in memory only until the command exits.")
        tap("Allow once")
        XCTAssertEqual(job.wait(30).0, 0)

        // keys: Deny.
        job = Harness.machine("m1", ["request", "--kind", "keys", "--subject", "volume:clients", "--new-key", "volume:vol-7"])
        card("Allow volume clients?")
        tap("Deny")
        XCTAssertEqual(job.wait(30).0, 2)

        // agent: Allow is remembered, and the next use answers by itself.
        let agent = ["request", "--kind", "agent", "--agent", "claude", "--repo-id", "github.com/acme/shop", "--names", "OPENAI_API_KEY",
                     "--use", "claude:github.com/acme/shop:OPENAI_API_KEY", "--subject", "secret:OPENAI_API_KEY",
                     "--key", "secrets:store-1", "--cmd", "npm test"]
        job = Harness.machine("m1", agent)
        card("Let claude use OPENAI_API_KEY?")
        see("First use of this key by claude in shop. Allow is remembered; remove it in Answers.")
        see("Agents ask once for each key in each repository.")
        tap("Allow")
        XCTAssertEqual(job.wait(30).0, 0)
        // The answer covers the named key; the key it comes in needs an Open session, as for
        // `keys` (SPEC 9.3), so the machine reports one first.
        XCTAssertEqual(Harness.machine("m1", ["status", "--state", "open", "--left", "7200"]).wait(20).0, 0)
        XCTAssertEqual(Harness.machine("m1", agent).wait(30).0, 0)

        tab("Settings")
        tap("Answers")
        see("may use")
        see("shop")
        tap("Remove")
        see("No answers yet.")
        tap("Back")

        tab("Activity")
        see("One tap")
        see("Denied")
        see("Allowed once")
        see("1 request declined")
        tab("Inventory")
        see("Secret store")
        see("qHWf")
    }

    func testExpiredWhileOpenAndSeveralWaiting() {
        restoreVectorWords()
        pairFakeMachine()
        let a = Harness.machine("m1", ["request", "--kind", "open", "--subject", "secret:A_KEY", "--new-key", "secrets:s-a"])
        card("Allow A_KEY?")
        let b = Harness.machine("m1", ["request", "--kind", "open", "--subject", "secret:B_KEY", "--new-key", "secrets:s-b",
                                       "--ttl", "8", "--timeout-secs", "20"])
        see("1 more waiting", 20)
        tap("Allow once")
        XCTAssertEqual(a.wait(30).0, 0)
        card("Allow B_KEY?")
        see("dev@mbp.example.com stopped waiting.", 30)
        tap("Close")
        XCTAssertEqual(b.wait(30).0, 3)
    }

    func testRelayBanners() {
        restoreVectorWords()
        FakeRelay.fail(["status": 429, "error": "rate_limited", "retryAfter": 3600, "scope": "phone", "times": 3])
        app.terminate()
        app.launchArguments = []
        app.launch()
        see("This phone has used its relay limit for today.", 30)
    }
}
