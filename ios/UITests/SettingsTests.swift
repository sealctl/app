import XCTest

/// SPEC.md 16.4 items 6 and 9, 11.18 to 11.19: Show words and Delete my relay data with the
/// level 3 delay and `finish`; Places without permission; About; Erase.
final class SettingsTests: SealctlTestCase {
    func testShowWordsAfterTheDelay() {
        onboardNewWords()
        tab("Settings")
        tap("Show words")
        see("Showing the words is a sensitive action. Every paired computer is told.")
        see("This starts one hour after you confirm.")
        tap("Confirm with Face ID")
        faceID(then: "Showing your words")
        see("Starts at")
        // The shortened hour ends; confirm again to finish.
        see("The hour is over. Confirm again to finish.", TimeInterval(Env.delay + 30))
        tap("Finish")
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
        tap("Delete my relay data")
        see("This unpairs your 1 machines")
        tap("Delete")
        faceID(then: "Deleting your relay data")
        see("The hour is over. Confirm again to finish.", TimeInterval(Env.delay + 30))
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
        faceID(then: "Starts at")
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
        tap("Erase sealctl from this phone")
        see("This removes your words, machines, places and history from this phone.")
        app.switches["Also remove the copy in iCloud Keychain"].coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
        tap("Erase")
        faceID(then: "Your phone holds the keys.", 30)
    }

    /// 11.4 "Backup found": Erase keeps the iCloud Keychain copy unless asked; Welcome then
    /// offers it first. (On an unsigned simulator the item stays on this device: no sync.)
    func testEraseKeepsTheICloudCopyAndRestoresFromIt() throws {
        onboardNewWords()
        tab("Settings")
        app.swipeUp()
        tap("Erase sealctl from this phone")
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
