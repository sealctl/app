import XCTest

/// Against the relay the tests are given (the staging relay in CI), with the fake machine:
/// fresh words, pairing, a level 1 answer, and a level 3 hand-back with its number, delay and
/// cancel. Nothing here needs the fake relay's test controls.
final class StagingTests: SealctlTestCase {
    func testFakeMachineThroughTheRelay() {
        onboardNewWords()
        pairFakeMachine("s1", name: "fake@staging.example.com", hint: "staging-1")

        let open = Harness.machine("s1", ["request", "--kind", "open", "--subject", "secret:DEMO_API_KEY", "--new-key",
                                          "secrets:demo-1", "--cmd", "npm test"])
        card("Allow DEMO_API_KEY?", 60)
        tap("Allow for this session")
        let (code, out) = open.wait(60)
        XCTAssertEqual(code, 0, out)
        XCTAssertTrue(out.contains("KEY secrets:demo-1"), out)

        let all = Harness.machine("s1", ["request", "--kind", "unseal", "--all", "--match", "--plan", "secrets:store:secrets:demo-1",
                                         "--plan", "pairing:fake@staging.example.com"])
        see("Which number does fake@staging.example.com show?", 60)
        tap("number \(all.find("NUMBER (\\d+)")!)")
        see("Hand back everything on fake@staging.example.com?")
        tap("Confirm with Face ID")
        faceID(then: "Starts at", 30)
        tap("Cancel")
        see("Cancelled. Nothing was handed back.", 30)
        XCTAssertEqual(all.wait(60).0, 4)
    }
}
