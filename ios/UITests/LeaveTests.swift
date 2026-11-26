import XCTest

/// SPEC.md 16.4 item 9 and 11.22: Leave sealctl with two fake machines, one handed back by
/// unpairing itself and one skipped; the delay, the card check, the relay data and Welcome.
final class LeaveTests: SealctlTestCase {
    override func setUpWithError() throws {
        try super.setUpWithError()
        try XCTSkipUnless(Env.fakeRelay, "deletes relay data")
    }

    func testLeaveSealctl() {
        restoreVectorWords()
        pairFakeMachine("m1", name: "dev@mbp.example.com")
        pairFakeMachine("m2", name: "ci@build.example.com", hint: "serial-2")
        tab("Settings")
        app.swipeUp()
        tap("Unseal all machines and leave")
        see("sealctl hands everything back to you before you go.")
        tap("Start")
        faceID(then: "Hand back each computer")
        see("Waiting for")
        // One computer runs `sealctl unseal --all`, which unpairs it as its last relay step.
        XCTAssertEqual(Harness.machine("m1", ["unpair"]).wait(30).0, 0)
        see("Handed back", 30)
        // The other is skipped.
        tap("Skip a computer")
        see("Use it when the computer is lost or already wiped.")
        tap("Skip")
        see("Skipped")
        tap("Continue")

        // Step 3: away from a trusted place, the (shortened) hour first.
        see("Delete your data and the last copy of your words?")
        tap("Confirm with Face ID")
        faceID(then: "Leaving sealctl")
        see("Ready until", TimeInterval(Env.delay + 30))
        tap("Finish")
        faceID(then: "Check your card first", 30)

        // Step 4: three words from the card.
        typeCardWords(3)

        // Steps 5 to 7.
        see("Deleting your relay data", 20)
        tap("Continue")
        see("What happened", 30)
        see("Relay data deleted.")
        see("ci@build.example.com: skipped")
        tap("Next")
        see("Keep your card for now")
        tap("Done")
        see("sealctl is gone from this phone. You can delete the app.", 30)
        see("Your phone holds the keys.")
    }
}
