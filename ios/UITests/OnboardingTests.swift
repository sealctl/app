import XCTest

/// SPEC.md 16.4 items 1 and 2: create words with the card check, restore from typed words.
final class OnboardingTests: SealctlTestCase {
    func testCreateWordsCheckTheCardBackupsAndNotifications() {
        onboardNewWords(wrongFirst: true)
        see("No machines yet.")
        tab("Settings")
        see("written on")
        XCTAssertEqual(words.count, 24)
        XCTAssertTrue(words.allSatisfy { !$0.isEmpty })
    }

    func testRestoreFromTypedWordsShowsTheFingerprint() {
        see("Your phone holds the keys.", 30)
        tap("Restore")
        see("Type your 24 words")
        see("Four letters are enough. Each word completes itself.")
        typeWords(Env.vectorWords)
        see("This is seed", 20)
        see("Does your card say qHWf?")
        tap("No, check again")
        see("Type your 24 words")
        tap("Back")
        see("Your phone holds the keys.")
    }

    /// 11.4: Face ID doesn't recognise the face and the prompt is cancelled. Nothing is restored,
    /// the screen says so and Yes asks again; the second prompt matches and the restore goes on.
    func testRestoreAfterAFailedFaceIDAsksAgain() {
        typeVectorWords()
        tap("Yes")
        failFaceID()
        see("Couldn't confirm it's you, so nothing was restored. Try again.")
        see("Does your card say qHWf?")
        XCTAssertTrue(app.buttons["Yes"].isEnabled, uiTree())
        XCTAssertFalse(shows("Found your backup", 1))
        tap("Yes")
        faceID(then: "Found your backup", 30)
        XCTAssertFalse(element("error").exists)
        words = Env.vectorWords
        tap("Continue")
        see("Where is your old phone?")
        tap("I still have it, or it was reset")
        finishOnboarding(restored: true)
        tab("Settings")
        see("qHWf")
    }

    func testBadChecksumAndDisabledLetters() {
        see("Your phone holds the keys.", 30)
        tap("Restore")
        see("Type your 24 words")
        // No BIP39 word starts with "q" followed by "x".
        app.buttons["key q"].tap()
        XCTAssertFalse(app.buttons["key x"].isEnabled)
        app.buttons["key delete"].tap()
        // "abandon" x 24 has a bad checksum.
        typeWords(Array(repeating: "abandon", count: 24))
        see("These words don't fit together. Check the order and spelling against your card.", 20)
    }

    func testRestoreThenMainTabs() {
        restoreVectorWords()
        tab("Activity")
        see("No key was written to disk.")
        see("Nothing yet. Every use of your keys shows here.")
        tab("Inventory")
        see("No keys handed out yet.")
        tab("Settings")
        see("qHWf")
    }
}
