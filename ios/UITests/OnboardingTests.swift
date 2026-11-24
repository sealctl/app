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
