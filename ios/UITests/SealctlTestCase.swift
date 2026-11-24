import XCTest

/// A fresh install for every test: the app erases its keychain items and database at launch
/// (`-resetForTests`, debug builds only), the fake relay and the harness start empty.
class SealctlTestCase: XCTestCase {
    var app: XCUIApplication!
    /// The words of this test's phone, read from the words pages or typed in.
    var words: [String] = []
    /// This test's phone has made its biometric gate. Before that, the first level 2 or 3
    /// confirmation asks two words from the card (SPEC.md 9.6).
    var gateMade = false

    override func setUpWithError() throws {
        continueAfterFailure = false
        try XCTSkipUnless(Harness.up, "the harness (ios/scripts/harness.py) is not running")
        Bio.enroll()
        Harness.reset()
        if Env.fakeRelay {
            FakeRelay.reset()
            FakeRelay.near(nil)
        }
        app = XCUIApplication()
        app.launchArguments = ["-resetForTests"]
        app.launchEnvironment = ["SEALCTL_RELAY": Env.relay, "SEALCTL_TEST_DELAY": "\(Env.delay)"]
        addUIInterruptionMonitor(withDescription: "system alerts") { alert in
            for b in ["Allow", "Allow While Using App", "Open", "OK", "Don’t Allow"] where alert.buttons[b].exists {
                alert.buttons[b].tap()
                return true
            }
            return false
        }
        app.launch()
    }

    override func tearDownWithError() throws {
        Harness.reset()
        if Env.fakeRelay { FakeRelay.near(nil) }
    }

    // MARK: failure messages

    /// Marks a screen that shows or takes recovery words. Mirrors WORD_SCREEN in
    /// ios/scripts/failure-attachments.py: change both together.
    static let wordScreen = #"identifier: '(?:word-\d|choice |field-\d|key )|Which is word|Words \d+ to \d+|Type your 24 words|Show my words"#

    /// The app's UI tree (or `of` another app's, such as springboard's) for a failure message,
    /// which ends up in the public job log. On a words screen the tree is withheld; only the ids
    /// of elements that carry no word are listed.
    func uiTree(_ limit: Int = 4000, of target: XCUIApplication? = nil) -> String {
        let tree = Env.scrub(String((target ?? app).debugDescription.prefix(limit)))
        guard tree.range(of: Self.wordScreen, options: .regularExpression) != nil else { return tree }
        let ids = tree.components(separatedBy: "identifier: '").dropFirst()
            .compactMap { $0.components(separatedBy: "'").first }
            .filter { !$0.isEmpty && Self.shown($0) == $0 }
        return "[UI tree withheld: a words screen] ids: " + ids.joined(separator: ", ")
    }

    /// An element id for a failure message: a card-check choice's id holds its word.
    static func shown(_ id: String) -> String {
        id.range(of: #"^(?:word-|choice |field-|key )"#, options: .regularExpression) == nil ? id : "[a word element]"
    }

    // MARK: finding and tapping

    func element(_ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    func text(_ contains: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", contains)).firstMatch
    }

    @discardableResult
    func see(_ contains: String, _ timeout: TimeInterval = 15, file: StaticString = #filePath, line: UInt = #line) -> XCUIElement {
        let e = text(contains)
        if !e.waitForExistence(timeout: timeout) {
            XCTFail("not shown: \(contains)\n\(uiTree())", file: file, line: line)
        }
        return e
    }

    func shows(_ contains: String, _ timeout: TimeInterval = 3) -> Bool { text(contains).waitForExistence(timeout: timeout) }

    func tap(_ id: String, _ timeout: TimeInterval = 15, file: StaticString = #filePath, line: UInt = #line) {
        let b = app.buttons[id]
        if b.waitForExistence(timeout: timeout) {
            waitHittable(b)
            b.tap()
            return
        }
        let e = element(id)
        if e.waitForExistence(timeout: 2) {
            e.tap()
            return
        }
        XCTFail("no button: \(Self.shown(id))\n\(uiTree())", file: file, line: line)
    }

    func waitHittable(_ e: XCUIElement, _ timeout: TimeInterval = 5) {
        let end = Date().addingTimeInterval(timeout)
        while !e.isHittable && Date() < end { Thread.sleep(forTimeInterval: 0.2) }
    }

    /// Taps a text field and types once it has keyboard focus. A tap made while the screen still
    /// moves can land before the field takes focus, and `typeText` then fails with "Neither element
    /// nor any descendant has keyboard focus". On a slow simulator (main runs 45242033275 and
    /// 45155371322: the restore before it took twice as long as in the other tests) focus can take
    /// longer than one short wait. So: up to three taps, each followed by up to 10 s of waiting for
    /// focus (on the field or inside it), all within 40 s; a tap only while focus has not come.
    /// The failure carries the UI tree, so the run keeps its screenshot.
    func enter(_ text: String, into field: XCUIElement, file: StaticString = #filePath, line: UInt = #line) {
        let focused = NSPredicate(format: "hasKeyboardFocus == true")
        let inside = field.descendants(matching: .any).matching(focused).firstMatch
        func hasFocus() -> Bool { field.exists && (focused.evaluate(with: field) || inside.exists) }
        let deadline = Date().addingTimeInterval(40)
        var taps = 0
        while !hasFocus() {
            guard taps < 3, Date() < deadline else {
                let keyboard = app.keyboards.firstMatch.exists ? "a keyboard is up" : "no keyboard"
                XCTFail("no keyboard focus: \(Self.shown(field.identifier)) after \(taps) taps, \(keyboard)\n\(uiTree(3000))",
                        file: file, line: line)
                return
            }
            waitHittable(field)
            field.tap()
            taps += 1
            let wait = min(deadline, Date().addingTimeInterval(10))
            while !hasFocus() && Date() < wait { Thread.sleep(forTimeInterval: 0.25) }
        }
        field.typeText(text)
    }

    /// Answers the Face ID prompt the last tap raised: matches until `next` shows.
    func faceID(then next: String, _ timeout: TimeInterval = 20, file: StaticString = #filePath, line: UInt = #line) {
        let end = Date().addingTimeInterval(timeout)
        Thread.sleep(forTimeInterval: 1)
        while Date() < end {
            if shows(next, 0.5) { return }
            Bio.match()
            Thread.sleep(forTimeInterval: 1)
        }
        see(next, 1, file: file, line: line)
    }

    /// Answers a level 2 or 3 confirmation the last tap raised. The first one on this phone
    /// asks two words from the card before Face ID makes the gate (SPEC.md 9.6).
    func gate(then next: String, _ timeout: TimeInterval = 20, file: StaticString = #filePath, line: UInt = #line) {
        if !gateMade {
            see("Before Face ID can confirm sensitive actions on this phone, type two words from your card.", 15, file: file, line: line)
            typeCardWords(2, file: file, line: line)
            gateMade = true
        }
        faceID(then: next, timeout, file: file, line: line)
    }

    /// The card check of 11.23: opens the words (Face ID or the passcode), types the words the
    /// fields ask for, and checks.
    func typeCardWords(_ count: Int, file: StaticString = #filePath, line: UInt = #line) {
        tap("Use my card", file: file, line: line)
        let fields = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'field-'"))
        let end = Date().addingTimeInterval(30)
        while !fields.firstMatch.exists && Date() < end {
            Bio.match()
            Thread.sleep(forTimeInterval: 1)
        }
        XCTAssertTrue(fields.firstMatch.waitForExistence(timeout: 5), uiTree(3000), file: file, line: line)
        let positions = (0..<fields.count).map { Int(fields.element(boundBy: $0).identifier.dropFirst(6))! }
        XCTAssertEqual(positions.count, count, file: file, line: line)
        typeWords(positions.map { words[$0 - 1] }, fields: positions)
        tap("Check", file: file, line: line)
    }

    /// Answers the notification permission alert, which only the first launch of a run sees
    /// (iOS asks once per install): SpringBoard's own "Allow"; the interruption monitor only
    /// when an alert without "Allow" shows. Tests that see no alert lose 2 s.
    func allowSystemAlert() {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let alert = springboard.alerts.firstMatch
        guard alert.waitForExistence(timeout: 2) else { return }
        if alert.buttons["Allow"].exists {
            alert.buttons["Allow"].tap()
        } else {
            nudge()
        }
    }

    /// Lets the interruption monitor answer a system alert.
    func nudge() {
        app.swipeUp()
        Thread.sleep(forTimeInterval: 0.5)
    }

    // MARK: onboarding (11.3)

    /// Create new words, write them down (read from the words pages), pass the card check
    /// with one wrong answer first, then backups, notifications and places.
    func onboardNewWords(wrongFirst: Bool = false) {
        see("Your phone holds the keys.", 30)
        tap("Create new words")
        see("24 words open everything")
        tap("Next")
        see("Print a blank card")
        see("No printer? Any paper works. Number 24 lines.")
        tap("I have a blank card")
        see("Write where no camera can see")
        tap("Show my words")
        faceID(then: "Words 1 to 6")
        words = []
        for page in 0..<4 {
            see("Words \(page * 6 + 1) to \(page * 6 + 6)")
            for i in page * 6 + 1...page * 6 + 6 {
                let row = element("word-\(i)")
                XCTAssertTrue(row.waitForExistence(timeout: 5), "word \(i) not readable")
                let label = row.label
                words.append(String(label.split(separator: ":").last ?? "").trimmingCharacters(in: .whitespaces))
            }
            if page < 3 { tap("Next") }
        }
        see("Now fill in the card")
        see("Words fingerprint:")
        tap("I've written all 24")
        for k in 1...3 {
            see("Check your card · \(k) of 3")
            let q = see("Which is word ").label
            let n = Int(q.filter(\.isNumber))!
            let right = words[n - 1]
            if wrongFirst && k == 1 {
                let wrong = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'choice ' AND identifier != %@", "choice \(right)")).firstMatch
                wrong.tap()
                see("That's not word \(n). Look at your card again.")
            }
            tap("choice \(right)")
        }
        finishOnboarding()
    }

    /// Backups, notifications, places, pair later.
    func finishOnboarding(restored: Bool = false) {
        see("Backups")
        see("Paper card")
        tap("Continue")
        see("Requests arrive as notifications")
        tap("Allow notifications")
        allowSystemAlert()
        if restored {
            see("Machines", 20)
            return
        }
        see("Learn your places?", 20)
        see("Without places, a session stays open up to 1 hour and reopening always takes a tap.")
        tap("Not now")
        see("Pair a machine")
        tap("Later")
        see("Machines", 20)
    }

    /// Restore from paper with the in-app keypad (11.4).
    /// Types words on the keypad, checking each field; `fields` are their numbers (default 1...).
    func typeWords(_ list: [String], fields: [Int]? = nil) {
        for (i, w) in list.enumerated() {
            let number = fields?[i] ?? i + 1
            let field = element("field-\(number)")
            for attempt in 0..<3 {
                if attempt > 0 {
                    // A missed tap: focus the field, clear it and type again.
                    guard field.exists else { break }
                    field.tap()
                    for _ in 0..<6 where app.buttons["key delete"].isEnabled { app.buttons["key delete"].tap() }
                }
                for c in w.prefix(4) {
                    let key = app.buttons["key \(c)"]
                    if !key.isHittable { waitHittable(key, 3) }
                    key.tap()
                }
                // After the last word the screen moves on and the field is gone.
                guard field.exists else { break }
                if ((field.value as? String) ?? "").hasPrefix(String(w.prefix(4))) { break }
            }
        }
    }

    func restoreVectorWords() {
        see("Your phone holds the keys.", 30)
        tap("Restore")
        see("Type your 24 words")
        typeWords(Env.vectorWords)
        see("These are words", 20)
        see("Does your card say qHWf?")
        tap("Yes")
        faceID(then: "Found your backup", 30)
        words = Env.vectorWords
        tap("Continue")
        see("Where is your old phone?")
        tap("I still have it, or it was reset")
        finishOnboarding(restored: true)
    }

    // MARK: machines

    /// Pairs a fake machine by typing its code (the simulator has no camera). Returns its home.
    @discardableResult
    func pairFakeMachine(_ home: String = "m1", name: String = "dev@mbp.example.com", hint: String? = "serial-1",
                         model: String = "MacBook Pro") -> String {
        var args = ["pair", "--name", name, "--model", model, "--no-wait", "--link-file", "/dev/null"]
        if let hint { args += ["--hint-raw", hint] }
        let job = Harness.machine(home, args)
        job.wait(30)
        guard let link = job.find("LINK (\\S+)", timeout: 5) else {
            XCTFail("no link: \(job.output)")
            return home
        }
        typePairingCode(link)
        confirmPairing(name)
        let (code, out) = Harness.machine(home, ["pair-wait", "--wait-secs", "60"]).wait(70)
        XCTAssertEqual(code, 0, out)
        return home
    }

    func typePairingCode(_ link: String) {
        if !app.buttons["Can't scan? Type the pairing code"].exists {
            if app.buttons["Scan code"].exists { tap("Scan code") } else { tap("Pair a machine") }
        }
        tap("Can't scan? Type the pairing code")
        let field = element("Pairing code")
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        enter(link, into: field)
        tap("Continue")
    }

    func confirmPairing(_ name: String, button: String = "Pair") {
        if button == "Pair" { see("Pair this machine?") }
        tap(button)
        gate(then: "Paired. \(name) can now ask this phone for keys.", 30)
        tap("Done")
    }

    /// Waits for the approval card of a request.
    @discardableResult
    func card(_ title: String, _ timeout: TimeInterval = 30, file: StaticString = #filePath, line: UInt = #line) -> XCUIElement {
        let t = element("card-title")
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if t.exists && t.label.contains(title) { return t }
            Thread.sleep(forTimeInterval: 0.5)
        }
        XCTFail("no card: \(title)\n\(uiTree())", file: file, line: line)
        return t
    }

    /// Goes to a tab.
    func tab(_ name: String) {
        let b = app.tabBars.buttons[name]
        if b.waitForExistence(timeout: 10) { b.tap() }
    }
}
