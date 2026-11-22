import Foundation
import Testing
import EngineKit
import Relay
import SealCore
import Vault
@testable import Engine

#if os(macOS)
/// The engine with the real `sealctl` CLI (SEALCTL_BIN) in a temporary HOME, against the relay
/// in SEALCTL_TEST_RELAY (the fake relay or the staging relay): pairing by the CLI's link,
/// `open`, secrets with and without own approval, an agent's first use, `unseal` of one secret
/// (level 2) and `unseal --all` (level 3) with the number, the delay, a cancel and the report.
@MainActor
@Suite(.enabled(if: testRelay != nil && cliBin != nil), .serialized)
struct CLIFlowTests {
    let name = "pairtest@ci.example.com"

    /// Lets the CLI command run, answering every card it raises with `choose`.
    func drive(_ engine: AppEngine, _ run: FakeMachine.Run, timeout: Double = 120,
               _ choose: (Waiting) async throws -> Void) async throws -> (Int32, String) {
        let end = Date().addingTimeInterval(timeout)
        var seen: Set<String> = []
        while run.process.isRunning && Date() < end {
            await engine.catchUp()
            for w in engine.waiting where !w.expired && !seen.contains(w.id) {
                seen.insert(w.id)
                try await choose(w)
            }
            try await Task.sleep(for: .milliseconds(200))
        }
        if run.process.isRunning { run.process.terminate() }
        return run.wait()
    }

    @Test func realCLIEndToEnd() async throws {
        let (engine, vault, _) = try await makeEngine(testDelay: 3)
        try await onboard(engine)
        let cli = CLIMachine()
        defer { cli.cleanup() }

        // Pairing by the link `sealctl pair` prints.
        let pair = try cli.start(["pair", "--name", name])
        let link = try await pair.find("(https://sealctl\\.com/p#\\S+)", timeout: 60)
        let offer = try engine.parseOffer(link).get()
        #expect(offer.name() == name)
        _ = try await engine.pair(offer, replaces: nil).get()
        var (code, out) = pair.wait()
        #expect(code == 0, "\(out)")

        // open (level 1): One tap.
        (code, out) = try await drive(engine, try cli.start(["open"])) { w in
            #expect(w.verdict.kind == .open)
            #expect(Texts.title(Texts.facts(w, machineName: self.name)) == "Open \(self.name)?")
            #expect(await engine.answer(w.id, .allowSession))
        }
        #expect(code == 0, "\(out)")

        // A secret, then an own-approval secret that asks at every use.
        (code, out) = try await drive(engine, try cli.start(["secret", "set", "test/one"], stdin: "a-test-value")) { w in
            await engine.answer(w.id, w.verdict.options[0])
        }
        #expect(code == 0, "\(out)")
        (code, out) = try await drive(engine, try cli.start(["secret", "set", "test/own", "--own-approval"], stdin: "own-value")) { w in
            await engine.answer(w.id, w.verdict.options[0])
        }
        #expect(code == 0, "\(out)")
        var kinds: [RequestKind] = []
        (code, out) = try await drive(engine, try cli.start(["run", "-e", "K=test/own", "--", "sh", "-c", "test -n \"$K\""])) { w in
            kinds.append(w.verdict.kind)
            await engine.answer(w.id, w.verdict.kind == .own ? .allowOnce : w.verdict.options[0])
        }
        #expect(code == 0, "\(out)")
        #expect(kinds.contains(.own), "\(kinds)")

        // An agent's first use of a secret here: remembered.
        kinds = []
        (code, out) = try await drive(engine, try cli.start(["run", "-e", "K=test/one", "--", "sh", "-c", "test -n \"$K\""],
                                                       env: ["SEALCTL_AGENT": "1"])) { w in
            kinds.append(w.verdict.kind)
            await engine.answer(w.id, w.verdict.kind == .agent ? .allow : w.verdict.options[0])
        }
        #expect(code == 0, "\(out)")

        // unseal of one secret (level 2): the number when the phone can't tell it is near.
        if testRelay!.hasPrefix("http://127.0.0.1") { _ = try await nearControl(false) }
        let one = try cli.start(["unseal", "secret", "test/one"], stdin: "y\n", tty: true)
        (code, out) = try await drive(engine, one) { w in
            #expect(w.verdict.level == 2)
            if w.verdict.needsNumber {
                let n = UInt32(try await one.find("pick (\\d+)"))!
                #expect(w.request.matchChoices().contains(n))
                #expect(w.request.checkMatch(pick: n))
            }
            #expect(await vault.gate(reason: "Confirm handing back \(self.name).") == .passed)
            #expect(await engine.confirmSensitive(w))
        }
        #expect(code == 0, "\(out)")

        // unseal --all (level 3): number, plan, delay; cancelled from the phone first.
        var all = try cli.start(["unseal", "--all"], stdin: "unseal\n", tty: true)
        (code, out) = try await drive(engine, all, timeout: 180) { w in
            #expect(w.verdict.level == 3)
            #expect(w.plan?.all == true)
            let n = UInt32(try await all.find("pick (\\d+)"))!
            #expect(w.request.matchChoices().contains(n))
            #expect(w.request.checkMatch(pick: n))
            #expect(await engine.confirmSensitive(w))
            #expect(await engine.cancelDelayed(w.id))
        }
        #expect(code != 0, "\(out)")

        // Again, and the (shortened) hour runs: the hand-back, its report, the unpairing.
        all = try cli.start(["unseal", "--all"], stdin: "unseal\n", tty: true)
        (code, out) = try await drive(engine, all, timeout: 300) { w in
            if w.verdict.level == 3 {
                let n = UInt32(try await all.find("pick (\\d+)"))!
                _ = w.request.matchChoices()
                #expect(w.request.checkMatch(pick: n))
                #expect(await engine.confirmSensitive(w))
            }
        }
        #expect(code == 0, "\(out)")
        for _ in 0..<20 where !engine.state.reports.contains(where: { $0.machineName == name }) {
            await engine.catchUp()
            try await Task.sleep(for: .milliseconds(300))
        }
        #expect(engine.state.reports.contains { $0.machineName == name })
        await engine.refreshMachines()
        #expect(engine.liveMachines.isEmpty)
        if testRelay!.hasPrefix("http://127.0.0.1") { _ = try await nearControl(nil) }
    }
}
#endif
