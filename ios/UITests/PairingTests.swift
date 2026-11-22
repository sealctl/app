import XCTest

/// SPEC.md 16.4 item 3: pairing by the typed code and by a link, the duplicate cards, tags,
/// nicknames, unpairing.
final class PairingTests: SealctlTestCase {
    override func setUpWithError() throws {
        try super.setUpWithError()
        try XCTSkipUnless(Env.fakeRelay, "uses the fake relay")
    }

    func testPairByTypedCodeThenDuplicateAndPairAsNew() {
        restoreVectorWords()
        see("No machines yet.")
        pairFakeMachine("m1", name: "dev@mbp.example.com", hint: "serial-1")
        see("dev@mbp.example.com", 10)

        // The same name and the same hardware: "Already paired".
        let job = Harness.machine("m2", ["pair", "--name", "dev@mbp.example.com", "--hint-raw", "serial-1", "--no-wait",
                                         "--link-file", "/dev/null"])
        job.wait(30)
        typePairingCode(job.find("LINK (\\S+)")!)
        see("Already paired")
        see("is already paired (same hardware, last seen")
        confirmPairing("dev@mbp.example.com", button: "Pair as new")
        XCTAssertEqual(Harness.machine("m2", ["pair-wait", "--wait-secs", "30"]).wait(40).0, 0)
        // Both show their tag.
        see("dev@mbp.example.com #", 10)

        // A different hint: "Same machine?" and Yes, replace it.
        let job3 = Harness.machine("m3", ["pair", "--name", "dev@mbp.example.com", "--hint-raw", "serial-9", "--model",
                                          "MacBook Air", "--no-wait", "--link-file", "/dev/null"])
        job3.wait(30)
        typePairingCode(job3.find("LINK (\\S+)")!)
        see("Same machine?")
        see("Another machine is already called dev@mbp.example.com")
        tap("Cancel")
        see("Machines")
    }

    func testLinkOpensTheScannerWithItsExplanation() {
        restoreVectorWords()
        let job = Harness.machine("m1", ["pair", "--name", "ci@build.example.com", "--no-wait", "--link-file", "/dev/null"])
        job.wait(30)
        let link = job.find("LINK (\\S+)")!
        // Universal links need a signed build; the app also claims sealctl:// for the same payload.
        Harness.openURL(link.replacingOccurrences(of: "https://sealctl.com/p", with: "sealctl://p"))
        see("Scan the code with sealctl. On a computer without a terminal, open the link in its browser to see the code.", 20)
        typePairingCode(link)
        confirmPairing("ci@build.example.com")
        XCTAssertEqual(Harness.machine("m1", ["pair-wait", "--wait-secs", "30"]).wait(40).0, 0)
    }

    func testCodeErrors() {
        restoreVectorWords()
        typePairingCode("hello")
        see("This isn't a sealctl pairing code.")
        let field = element("Pairing code")
        field.tap()
        field.typeText(String(repeating: "\u{8}", count: 5) + "https://sealctl.com/p#v=1&m=x")
        tap("Continue")
        see("This isn't a sealctl pairing code.")
    }

    func testNicknameLockAndUnpair() {
        restoreVectorWords()
        pairFakeMachine("m1")
        // The machine reports Open: the row and the detail follow.
        XCTAssertEqual(Harness.machine("m1", ["status", "--state", "open", "--left", "7200"]).wait(20).0, 0)
        app.terminate()
        app.launchArguments = []
        app.launch()
        see("Open · ", 30)
        tap("machine dev@mbp.example.com")
        see("Lock now")
        let listen = Harness.machine("m1", ["listen", "--secs", "20", "--count", "1"])
        Thread.sleep(forTimeInterval: 1)
        tap("Lock now")
        let (_, out) = listen.wait(30)
        XCTAssertTrue(out.contains("lock"), out)
        let nick = element("Nickname")
        nick.tap()
        nick.typeText("Work laptop")
        tap("Save nickname")
        tap("Unpair")
        see("Unpair Work laptop?")
        let unpair = app.buttons.matching(identifier: "Unpair").element(boundBy: 0)
        unpair.tap()
        see("No machines yet.", 20)
    }
}
