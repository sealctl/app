import XCTest

/// SPEC.md 16.4 items 6 and 9, 11.18 to 11.19: Show words and Delete my relay data with the
/// level 3 delay and `finish`; Places without permission; About; Erase.
final class SettingsTests: SealctlTestCase {
    func testShowWordsAfterTheDelay() {
        onboardNewWords()
        tab("Settings")
        tap("Show words")
        see("Showing the words is a sensitive action. Every paired computer is told.")
        see("This starts two hours after you confirm.")
        tap("Confirm with Face ID")
        // The first level 3 action on this phone: two card words first (9.6).
        gate(then: "Showing your words")
        see("goes ahead at")
        // Show words again while it waits: the same delay, not a second start (11.23).
        tap("Back")
        tap("Show words")
        see("goes ahead at")
        XCTAssertFalse(app.buttons["Confirm with Face ID"].exists)
        // The shortened wait ends with the screen open: ready by itself, no notification needed.
        see("Ready until", TimeInterval(Env.delay + 30))
        tap("Show my words")
        faceID(then: "Your words", 30)
        // Face ID or the passcode for the words themselves.
        let first = element("word-1")
        let end = Date().addingTimeInterval(20)
        while !first.exists && Date() < end {
            Bio.match()
            Thread.sleep(forTimeInterval: 1)
        }
        XCTAssertTrue(first.waitForExistence(timeout: 5))
        XCTAssertEqual(first.label, "Word 1: \(words[0])")
        see("Correct your card, then check again.")
        tap("Back")
    }

    func testDeleteRelayDataAfterTheDelay() throws {
        try XCTSkipUnless(Env.fakeRelay, "deletes relay data")
        restoreVectorWords()
        pairFakeMachine()
        tab("Settings")
        tap("Delete relay data and unpair")
        see("This unpairs your 1 machines")
        tap("Delete")
        faceID(then: "Deleting your relay data")
        see("Ready until", TimeInterval(Env.delay + 30))
        tap("Finish")
        faceID(then: "Deleted. The relay has nothing for these words.", 30)
        tap("Done")
        tab("Machines")
        see("No machines yet.")
    }

    func testCancelAPhoneActionFromTheBanner() {
        onboardNewWords()
        tab("Settings")
        tap("Show words")
        tap("Confirm with Face ID")
        gate(then: "goes ahead at")
        tap("Cancel")
        see("Cancelled. Nothing happened.", 20)
    }

    func testPlacesAnswersDevicesAboutAndErase() {
        onboardNewWords()
        tab("Settings")
        tap("Places")
        see("Places need location access.")
        tap("Back")
        tap("Answers")
        see("No answers yet.")
        tap("Back")
        tap("Phones getting requests")
        tap("Back")
        app.swipeUp()
        see("core 0.7")
        see("protocol 1")
        tap("Remove from this phone")
        see("This removes your words, machines, places and history from this phone.")
        app.switches["Also remove the copy in iCloud Keychain"].coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
        tap("Erase")
        faceID(then: "Your phone holds the keys.", 30)
    }

    /// 11.18 Licences: the app's licences and the bundled Rust crate notices.
    func testLicencesListTheRustCrates() {
        onboardNewWords()
        tab("Settings")
        app.swipeUp()
        see("core 0.7").tap()
        tap("Licences")
        see("sealctl app: AGPL-3.0. sealctl-core: MIT.")
        see("Rust crates in the sealctl app")
        tap("Back")
        see("Source code")
    }

    /// 11.4 "Backup found": Erase keeps the iCloud Keychain copy unless asked; Welcome then
    /// offers it first. (On an unsigned simulator the item stays on this device: no sync.)
    func testEraseKeepsTheICloudCopyAndRestoresFromIt() throws {
        onboardNewWords()
        tab("Settings")
        app.swipeUp()
        tap("Remove from this phone")
        tap("Erase")
        faceID(then: "sealctl", 30)
        if !shows("Your words are in iCloud Keychain", 10) {
            throw XCTSkip("the simulator's keychain kept no synchronizable item")
        }
        tap(app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Restore '")).firstMatch.label)
        faceID(then: "Found your backup", 30)
        tap("Continue")
        see("Where is your old phone?")
        tap("I still have it, or it was reset")
        finishOnboarding(restored: true)
    }
}
