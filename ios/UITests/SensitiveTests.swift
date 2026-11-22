import XCTest

/// SPEC.md 16.4 item 11: levels 2 and 3 against the fake machine and fake relay.
final class SensitiveTests: SealctlTestCase {
    override func setUpWithError() throws {
        try super.setUpWithError()
        try XCTSkipUnless(Env.fakeRelay, "uses the fake relay's near control")
    }

    func testLevelTwoNumberRightThenWrongHoldAndRelease() {
        restoreVectorWords()
        pairFakeMachine()
        FakeRelay.near(false)

        // Not near, with `match`: the number comes first.
        var job = Harness.machine("m1", ["request", "--kind", "unseal", "--plan", "volume:safe:volume:vol-1", "--match"])
        see("Which number does dev@mbp.example.com show?", 30)
        see("Look at the terminal where you ran the command.")
        let n = job.find("NUMBER (\\d+)")!
        tap("number \(n)")
        see("Hand back volume safe from dev@mbp.example.com?")
        tap("Confirm with Face ID")
        faceID(then: "Confirmed")
        tap("Done")
        XCTAssertEqual(job.wait(30).0, 0)

        // A wrong number: refused, and the machine is held for an hour.
        job = Harness.machine("m1", ["request", "--kind", "unseal", "--plan", "volume:other:volume:vol-2", "--match"])
        see("Which number does dev@mbp.example.com show?", 30)
        let right = job.find("NUMBER (\\d+)")!
        let wrong = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'number ' AND identifier != %@", "number \(right)")).firstMatch
        wrong.tap()
        see("That's not the number on dev@mbp.example.com")
        see("For the next hour this phone ignores sensitive requests from that computer.")
        tap("Close")
        let (code, out) = job.wait(30)
        XCTAssertEqual(code, 2)
        XCTAssertTrue(out.contains("no_match"), out)
        tap("machine dev@mbp.example.com")
        see("after a wrong number.")
        tap("Release now")
        Thread.sleep(forTimeInterval: 1)
        Bio.match()
        let held = text("after a wrong number.")
        let end = Date().addingTimeInterval(15)
        while held.exists && Date() < end {
            Bio.match()
            Thread.sleep(forTimeInterval: 1)
        }
        XCTAssertFalse(held.exists)

        // Not near and no number: refused with not_near.
        let far = Harness.machine("m1", ["request", "--kind", "unseal", "--plan", "backup:b:backup:b-1"])
        let (fc, fout) = far.wait(30)
        XCTAssertEqual(fc, 2)
        XCTAssertTrue(fout.contains("not_near"), fout)
    }

    func testLevelThreeDelayCancelThenReleaseAndReport() {
        restoreVectorWords()
        pairFakeMachine()
        let plan = ["--plan", "secrets:store:secrets:store-1", "--plan", "volume:safe:volume:vol-1", "--plan", "ssh:ed25519",
                    "--plan", "pairing:dev@mbp.example.com"]

        // Away from a trusted place (no location): the hour, shortened in this build; cancel here.
        var job = Harness.machine("m1", ["request", "--kind", "unseal", "--all", "--match"] + plan)
        see("Which number does dev@mbp.example.com show?", 30)
        tap("number \(job.find("NUMBER (\\d+)")!)")
        see("Hand back everything on dev@mbp.example.com?")
        see("sealctl unseal --all moves these to passwords of your own.")
        see("volume · safe")
        see("pairing · dev@mbp.example.com")
        see("This starts one hour after you confirm.")
        tap("Confirm with Face ID")
        faceID(then: "Leaving sealctl on dev@mbp.example.com")
        see("Starts at")
        see("You approved this away from your trusted places")
        tap("Cancel")
        see("Cancelled. Nothing was handed back.", 20)
        XCTAssertEqual(job.wait(30).0, 4)
        tap("Close")

        // Again, and let the delay run: the machine fetches the approval.
        job = Harness.machine("m1", ["request", "--kind", "unseal", "--all", "--match"] + plan)
        see("Which number does dev@mbp.example.com show?", 30)
        tap("number \(job.find("NUMBER (\\d+)")!)")
        tap("Confirm with Face ID")
        faceID(then: "Starts at")
        let (code, out) = job.wait(TimeInterval(Env.delay + 60))
        XCTAssertEqual(code, 0, out)
        tap("Close", TimeInterval(Env.delay + 30))

        // The machine reports what it handed back: the report opens from Activity.
        let report = Harness.machine("m1", ["request", "--kind", "report", "--handback", "secrets:store:macOS Keychain:done",
                                            "--handback", "volume:safe:macOS Keychain:done", "--handback", "ssh:ed25519:~/.ssh/ed25519:failed",
                                            "--run", "~/.sealctl-unseal/2026-11-21T10-12-03"])
        XCTAssertEqual(report.wait(60).0, 0)
        tab("Activity")
        tap("dev@mbp.example.com handed everything back")
        see("2 of 3 done")
        see("secrets · store → macOS Keychain")
        see("unseal --resume")
        see("Your other computers were told.")
        tap("Done")
    }

    func testLevelThreeCancelledFromTheComputer() {
        restoreVectorWords()
        pairFakeMachine()
        let job = Harness.machine("m1", ["request", "--kind", "unseal", "--all", "--match", "--plan", "pairing:dev@mbp.example.com"])
        see("Which number does dev@mbp.example.com show?", 30)
        tap("number \(job.find("NUMBER (\\d+)")!)")
        tap("Confirm with Face ID")
        faceID(then: "Starts at")
        let id = job.find("DELAYED id=(\\S+)")!
        XCTAssertEqual(Harness.machine("m1", ["delayed", "cancel", id]).wait(30).0, 0)
        see("Cancelled from dev@mbp.example.com.", 40)
        XCTAssertEqual(job.wait(30).0, 4)
    }
}
