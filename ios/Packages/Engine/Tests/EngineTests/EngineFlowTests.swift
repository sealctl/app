import Foundation
import Testing
import EngineKit
import Relay
import SealCore
import Vault
@testable import Engine

#if os(macOS)
/// Sets the relay's `near` for the next requests (nil: computed from addresses).
func nearControl(_ near: Bool?) async throws -> Data {
    var req = URLRequest(url: URL(string: testRelay! + "/test/near")!)
    req.httpMethod = "POST"
    req.httpBody = near.map { "{\"near\": \($0)}" }.map { Data($0.utf8) } ?? Data("{\"near\": null}".utf8)
    return try await URLSession.shared.data(for: req).0
}

/// The engine end to end against the fake relay and a fake machine (SPEC.md 16.2): pairing,
/// every level 1 answer, remembered answers, reports, the level 2 number match and hold, the
/// level 3 plan with its delay and cancel, actions on the phone, locks and sync.
@MainActor
@Suite(.enabled(if: testRelay != nil && machineBin != nil), .serialized)
struct EngineFlowTests {
    /// Polls the relay until a request is waiting on the phone.
    func waitForCard(_ engine: AppEngine, _ count: Int = 1, _ run: FakeMachine.Run? = nil) async throws -> Waiting {
        for _ in 0..<100 {
            await engine.catchUp()
            let live = engine.waiting.filter { !$0.expired }
            if live.count >= count { return live.last! }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw RelayError.transport("no request arrived: \(run?.output ?? "")")
    }

    func paired() async throws -> (AppEngine, MemoryVault, RecordingNotifier, FakeMachine) {
        let (engine, vault, notifier) = try await makeEngine()
        try await onboard(engine)
        #expect(engine.phase == .ready)
        let m = FakeMachine()
        let link = m.home.appendingPathComponent("link")
        let (code, out) = try m.run(["pair", "--name", "dev@mbp.example.com", "--model", "MacBook Pro", "--hint-raw", "serial-1",
                                     "--no-wait", "--link-file", link.path])
        #expect(code == 0, "\(out)")
        let text = try String(contentsOf: link, encoding: .utf8)
        let offer = try engine.parseOffer(text).get()
        #expect(offer.name() == "dev@mbp.example.com")
        _ = try await engine.pair(offer, replaces: nil).get()
        #expect(try m.run(["pair-wait", "--wait-secs", "20"]).0 == 0)
        #expect(engine.liveMachines.count == 1)
        return (engine, vault, notifier, m)
    }

    @Test func pairingAndLevelOneAnswers() async throws {
        let (engine, _, _, m) = try await paired()

        // open: Allow for this session hands out the key.
        var r = try m.start(["request", "--kind", "open", "--subject", "secret:OPENAI_API_KEY", "--new-key", "secrets:store-1",
                             "--cmd", "npm test", "--cwd", "~/dev/shop"])
        var w = try await waitForCard(engine, 1, r)
        #expect(w.verdict.asking == .oneTap)
        #expect(Texts.title(Texts.facts(w, machineName: engine.displayName(w.machine))) == "Allow OPENAI_API_KEY?")
        #expect(w.verdict.options == [.allowSession, .allowOnce, .deny])
        #expect(await engine.answer(w.id, .allowSession))
        var (code, out) = await m.waitAsync(r)
        #expect(code == 0, "\(out)")
        #expect(out.contains("KEY secrets:store-1"))
        #expect(engine.toast?.text == "Allowed for this session")
        #expect(engine.state.inventory.contains { $0.id == "store-1" })

        // Deny.
        r = try m.start(["request", "--kind", "own", "--subject", "secret:DEPLOY_TOKEN", "--new-key", "secret:own-1",
                         "--cmd", "./deploy.sh"])
        w = try await waitForCard(engine, 1, r)
        #expect(Texts.title(Texts.facts(w, machineName: "x")) == "Allow DEPLOY_TOKEN once?")
        #expect(await engine.answer(w.id, .deny))
        (code, _) = await m.waitAsync(r)
        #expect(code == 2)

        // An agent's first use is remembered; the second use answers by itself.
        let agentArgs = ["request", "--kind", "agent", "--agent", "claude", "--repo-id", "github.com/acme/shop",
                         "--names", "OPENAI_API_KEY", "--use", "claude:github.com/acme/shop:OPENAI_API_KEY",
                         "--subject", "secret:OPENAI_API_KEY", "--key", "secrets:store-1", "--cmd", "npm test"]
        r = try m.start(agentArgs)
        w = try await waitForCard(engine, 1, r)
        #expect(w.verdict.kind == .agent)
        #expect(await engine.answer(w.id, .allow))
        (code, out) = await m.waitAsync(r)
        #expect(code == 0, "\(out)")
        #expect(engine.state.answers.filter { !$0.deleted }.count == 1)
        // The answer covers the named key; the key it comes in needs an Open session, as for
        // `keys` (SPEC 9.3), so the machine reports one first.
        #expect(try m.run(["status", "--state", "open", "--left", "3600"]).0 == 0)
        await engine.refreshStatus()
        r = try m.start(agentArgs)
        for _ in 0..<50 where r.process.isRunning {
            await engine.catchUp()
            try await Task.sleep(for: .milliseconds(100))
        }
        (code, _) = await m.waitAsync(r)
        #expect(code == 0)

        // A report is recorded silently; a hand-back opens the report.
        r = try m.start(["request", "--kind", "report", "--state", "open", "--left", "3600",
                         "--handback", "secrets:store:macOS Keychain:done", "--handback", "volume:safe:folder:failed"])
        for _ in 0..<50 where r.process.isRunning {
            await engine.catchUp()
            try await Task.sleep(for: .milliseconds(100))
        }
        (code, _) = await m.waitAsync(r)
        #expect(code == 0)
        #expect(engine.state.reports.count == 1)
        #expect(MachineView.of(engine.liveMachines[0], engine).state == .open)

        // Activity: the uses and the denial.
        let log = await engine.usage(machine: nil)
        #expect(log.contains { $0.outcome == "denied" })
        #expect(log.contains { $0.outcome == "one_tap" })
        let month = String(Texts.isoDate(nowMs()).prefix(7))
        #expect((engine.state.summaries.first { $0.month == month }?.requestsDeclined ?? 0) >= 1)

        // Lock: the machine hears it on its channel.
        let listen = try m.start(["listen", "--secs", "10", "--count", "2"])
        try await Task.sleep(for: .milliseconds(300))
        #expect(await engine.lock(engine.liveMachines[0]))
        let (lc, lout) = await m.waitAsync(listen)
        #expect(lc == 0)
        #expect(lout.contains("lock"), "\(lout)")
    }

    @Test func levelTwoNumberMatchAndHold() async throws {
        let (engine, vault, _, m) = try await paired()
        _ = try await nearControl(false)
        defer { Task { _ = try? await nearControl(nil) } }
        var r = try m.start(["request", "--kind", "unseal", "--plan", "volume:safe:volume:vol-1", "--match"])
        var w = try await waitForCard(engine, 1, r)
        #expect(w.verdict.asking == .inApp)
        #expect(w.verdict.level == 2)
        #expect(w.verdict.needsNumber)
        let choices = w.request.matchChoices()
        #expect(choices.count == 3)
        let right = try await r.number()
        #expect(choices.contains(right))
        // One pick only: the core keeps the right number and counts the first answer.
        #expect(w.request.checkMatch(pick: right))
        #expect(await vault.gate(reason: "Confirm handing back dev@mbp.example.com.") == .passed)
        #expect(await engine.confirmSensitive(w))
        var (code, out) = await m.waitAsync(r)
        #expect(code == 0, "\(out)")

        // A wrong number refuses and holds the machine for an hour (another object: the first
        // plan's later parts would be answered without asking).
        r = try m.start(["request", "--kind", "unseal", "--plan", "volume:other:volume:vol-2", "--match"])
        w = try await waitForCard(engine, 1, r)
        await engine.wrongNumber(w)
        (code, out) = await m.waitAsync(r)
        #expect(code == 2)
        #expect(out.contains("no_match"))
        #expect(engine.local.holds.contains { $0.machine == w.machine.key })
        r = try m.start(["request", "--kind", "unseal", "--plan", "backup:b:backup:b-1", "--match"])
        for _ in 0..<50 where r.process.isRunning {
            await engine.catchUp()
            try await Task.sleep(for: .milliseconds(100))
        }
        (code, out) = await m.waitAsync(r)
        #expect(out.contains("held"))
        await engine.releaseHold(w.machine.key)
        #expect(engine.local.holds.isEmpty)
    }

    @Test func levelThreeDelayCancelAndRelease() async throws {
        let (engine, vault, notifier, m) = try await paired()
        _ = try await nearControl(false)
        let plan = ["--plan", "secrets:store:secrets:store-1", "--plan", "volume:safe:volume:vol-1", "--plan", "pairing:dev@mbp.example.com"]
        var r = try m.start(["request", "--kind", "unseal", "--all", "--match"] + plan)
        var w = try await waitForCard(engine, 1, r)
        #expect(w.verdict.level == 3)
        #expect(w.verdict.needsNumber)
        #expect(w.plan?.items.count == 3)
        #expect(Texts.title(Texts.facts(w, machineName: "dev@mbp.example.com")) == "Hand back everything on dev@mbp.example.com?")
        #expect(engine.placeKind() == .noLocation)
        let n1 = try await r.number()
        #expect(w.request.matchChoices().contains(n1))
        #expect(w.request.checkMatch(pick: n1))
        #expect(await vault.gate(reason: "x") == .passed)
        #expect(await engine.confirmSensitive(w))
        let d = try #require(engine.local.delayed.first { $0.id == w.id })
        #expect(d.state == "waiting")
        #expect(await engine.cancelDelayed(d.id))
        var (code, out) = await m.waitAsync(r)
        #expect(code == 4, "\(out)")
        #expect(engine.local.delayed.first { $0.id == d.id }?.state == "cancelled")

        // Without a cancel the machine fetches the approval when the (shortened) hour ends.
        r = try m.start(["request", "--kind", "unseal", "--all", "--match"] + plan)
        w = try await waitForCard(engine, 1, r)
        let n2 = try await r.number()
        #expect(w.request.matchChoices().contains(n2))
        #expect(w.request.checkMatch(pick: n2))
        #expect(await engine.confirmSensitive(w))
        (code, out) = await m.waitAsync(r)
        #expect(code == 0, "\(out)")
        _ = notifier
        _ = try await nearControl(nil)
    }

    @Test func phoneActionWaitsForTheRelay() async throws {
        let (engine, _, _, _) = try await paired()
        let d = try #require(try await engine.startPhoneAction("words"))
        #expect(await engine.finishPhoneAction(d.id) == "too_early")
        try await Task.sleep(for: .milliseconds(2500))
        #expect(await engine.finishPhoneAction(d.id) == nil)

        let d2 = try #require(try await engine.startPhoneAction("delete"))
        #expect(await engine.cancelDelayed(d2.id))
        try await Task.sleep(for: .milliseconds(2500))
        #expect(await engine.finishPhoneAction(d2.id)?.hasPrefix("cancelled") == true)
    }

    @Test func syncUploadDownloadAndDelete() async throws {
        let (engine, _, _, _) = try await paired()
        await engine.setNickname(engine.liveMachines[0].key, "Work laptop")
        #expect(await engine.upload())
        #expect(await engine.download())
        #expect(engine.liveMachines[0].nickname == "Work laptop")
        let r = await engine.deleteRelayData(lockFirst: true)
        #expect(r.ok)
        #expect(engine.liveMachines.isEmpty)
        #expect(!engine.state.settings.relayBackup)
    }

    @Test func unpairAndErase() async throws {
        let (engine, _, _, _) = try await paired()
        #expect(await engine.unpair(engine.liveMachines[0]))
        #expect(engine.liveMachines.isEmpty)
        await engine.erase(alsoBackup: true)
        #expect(engine.phase == .noWords)
    }
}
#endif

@MainActor
struct EngineUnitTests {
    @Test func phases() async throws {
        let (engine, vault, _) = try await makeEngine()
        await engine.computePhase()
        #expect(engine.phase == .noWords)
        await vault.set(secure: false)
        await engine.computePhase()
        #expect(engine.phase == .needsScreenLock)
        await vault.set(secure: true)
        #expect(await engine.words.create() == .passed)
        UserDefaults.standard.set(true, forKey: "com.sealctl.installed")
        await engine.computePhase()
        #expect(engine.phase == .cardUnchecked)
        await engine.words.cardChecked()
        #expect(engine.phase == .onboarding(step: 7))
        #expect(await vault.readSyncBackup() != nil)
        await vault.dropPasscodeItems()
        await engine.computePhase()
        #expect(engine.phase == .wordsLost(reason: .passcodeRemoved))
    }

    @Test func backupFoundAfterErase() async throws {
        let (engine, vault, _) = try await makeEngine()
        try await onboard(engine)
        await vault.erase()
        engine.forgetPhoneKeys()
        await engine.computePhase()
        if case .backupFound(let fp, _) = engine.phase {
            #expect(fp == engine.state.words?.fingerprint)
        } else {
            Issue.record("expected backupFound, got \(engine.phase)")
        }
    }

    @Test func cardCheckChoicesAndMatches() async throws {
        let (engine, _, _) = try await makeEngine()
        #expect(await engine.words.create() == .passed)
        let words = try #require(engine.words.shown)
        #expect(words.count == 24)
        let pos = engine.words.positions(count: 3, groups: 2)
        #expect(pos.count == 3)
        #expect(pos.contains { $0 <= 12 } && pos.contains { $0 > 12 })
        let choices = engine.words.choices(pos[0])
        #expect(choices.count == 4)
        #expect(choices.contains(words[pos[0] - 1]))
        #expect(engine.words.matches(pos[0], String(words[pos[0] - 1].prefix(4))))
        engine.words.release()
        #expect(!engine.words.hasSession)
    }

    @Test func pairingCodeErrors() async throws {
        let (engine, _, _) = try await makeEngine()
        guard case .failure(let e) = engine.parseOffer("hello") else { Issue.record("parsed"); return }
        #expect(e.text == Texts.notACode)
        #expect(AppEngine.normalizeLink("sealctl://p#abc") == "https://sealctl.com/p#abc")
    }

    @Test func wording() {
        #expect(Texts.cut(String(repeating: "a", count: 100)).count == 80)
        #expect(Texts.duration(7800) == "2 h 10 min")
        #expect(Texts.duration(30) == "1 min")
        #expect(Texts.agentName("claude") == "Claude Code")
        #expect(Texts.isoDate(0).count == 10)
        let f = Texts.Facts(kind: .open, level: 1, subjectKind: "volume", subjectName: "clients", machineName: "dev@mbp")
        #expect(Texts.title(f) == "Mount volume clients?")
        let g = Texts.Facts(kind: .open, level: 1, machineName: "dev@mbp")
        #expect(Texts.title(g) == "Open dev@mbp?")
        let n = Texts.notification(Texts.Facts(kind: .unseal, level: 3, machineName: "dev@mbp"))
        #expect(n.title == "Unseal everything on dev@mbp?")
        #expect(Texts.notification(Texts.Facts(kind: .rewrap, level: 2, machineName: "m")).body == "Open sealctl to confirm with Face ID.")
    }
}
