import XCTest

/// End to end with the real `sealctl` CLI in a temporary HOME (sealctl's scripts/pair-test.sh
/// environment), against the fake or the staging relay: pairing by its link, `open`, secrets
/// with and without own approval, an agent's first use, `unseal` of one secret (level 2) and
/// `unseal --all` (level 3) with the number, the delay, a cancel, and the report.
final class CLIEndToEndTests: SealctlTestCase {
    let name = "pairtest@ci.example.com"

    override func setUpWithError() throws {
        try super.setUpWithError()
        try XCTSkipUnless(Harness.hasCLI, "no sealctl CLI in the harness (SEALCTL_BIN)")
    }

    /// Runs a CLI command and answers the phone's card with `button` while it runs.
    @discardableResult
    func run(_ args: [String], stdin: String? = nil, env: [String: String] = [:], card title: String? = nil,
             button: String? = nil, timeout: TimeInterval = 120) -> (Int, String) {
        let job = Harness.cli("c1", args, stdin: stdin, env: env)
        if let title, let button {
            card(title, 60)
            tap(button)
        }
        return job.wait(timeout)
    }

    func pairCLI() {
        let job = Harness.cli("c1", ["pair", "--name", name])
        guard let link = job.find("(https://sealctl\\.com/p#\\S+)", timeout: 60) else {
            XCTFail("no pairing link: \(job.output)")
            return
        }
        typePairingCode(link)
        confirmPairing(name)
        let (code, out) = job.wait(60)
        XCTAssertEqual(code, 0, out)
        XCTAssertTrue(out.contains("Paired"), out)
    }

    func testRealCLIEndToEnd() {
        if Env.fakeRelay { restoreVectorWords() } else { onboardNewWords() }
        pairCLI()
        see(name, 10)

        // open (level 1, One tap): the session opens.
        var (code, out) = run(["open"], card: "Open \(name)?", button: "Allow for this session")
        XCTAssertEqual(code, 0, out)

        // A secret in the store; then an own-approval secret, asked at every use.
        (code, out) = run(["secret", "set", "test/one"], stdin: "a-test-value")
        XCTAssertEqual(code, 0, out)
        let own = Harness.cli("c1", ["secret", "set", "test/own", "--own-approval"], stdin: "own-value")
        if text("Allow").waitForExistence(timeout: 20), element("card-title").exists {
            tap(app.buttons["Allow"].exists ? "Allow" : "Allow once")
        }
        XCTAssertEqual(own.wait(60).0, 0, own.output)
        (code, out) = run(["run", "-e", "K=test/own", "--", "sh", "-c", "test -n \"$K\""], card: "test/own", button: "Allow once")
        XCTAssertEqual(code, 0, out)

        // An agent's first use of a secret in this folder: remembered.
        (code, out) = run(["run", "-e", "K=test/one", "--", "sh", "-c", "test -n \"$K\""], env: ["SEALCTL_AGENT": "1"],
                          card: "test/one", button: "Allow")
        XCTAssertEqual(code, 0, out)

        // unseal of one secret (level 2): the number when the phone can't tell it is near.
        if Env.fakeRelay { FakeRelay.near(false) }
        let one = Harness.cli("c1", ["unseal", "secret", "test/one"], stdin: "y\n", tty: true)
        if text("Which number does").waitForExistence(timeout: 60) {
            let n = one.find("pick (\\d+)", timeout: 10)!
            tap("number \(n)")
        }
        see("Hand back", 30)
        tap("Confirm with Face ID")
        faceID(then: "Confirmed", 30)
        tap("Done")
        (code, out) = one.wait(120)
        XCTAssertEqual(code, 0, out)

        // unseal --all (level 3): the number, the plan, the delay; cancelled here first.
        var all = Harness.cli("c1", ["unseal", "--all"], stdin: "unseal\n", tty: true)
        see("Which number does", 90)
        tap("number \(all.find("pick (\\d+)", timeout: 10)!)")
        see("Hand back everything on \(name)?")
        tap("Confirm with Face ID")
        faceID(then: "Starts at", 30)
        tap("Cancel")
        see("Cancelled. Nothing was handed back.", 30)
        (code, out) = all.wait(120)
        XCTAssertNotEqual(code, 0, out)
        tap("Close")

        // Again, and let the (shortened) hour run: the computer hands everything back, sends
        // its report and unpairs itself.
        all = Harness.cli("c1", ["unseal", "--all"], stdin: "unseal\n", tty: true)
        see("Which number does", 90)
        tap("number \(all.find("pick (\\d+)", timeout: 10)!)")
        tap("Confirm with Face ID")
        faceID(then: "Starts at", 30)
        (code, out) = all.wait(TimeInterval(Env.delay + 240))
        XCTAssertEqual(code, 0, out)
        tap("Close", 30)
        tab("Activity")
        see("\(name) handed everything back", 60)
    }
}
