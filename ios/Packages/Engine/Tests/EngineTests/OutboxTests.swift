import Foundation
import Testing
import EngineKit
import Relay
import SealCore
@testable import Engine

/// The outbox of locks and notices (SPEC.md 8.1, 9.6, 11.9), with a scripted relay and clock.
@MainActor
@Suite struct OutboxTests {
    @MainActor
    final class Script {
        var clock: Int64 = 1_795_266_000_000
        var sent: [String] = []
        var delivered: [String] = []
        var wakes: [Int64] = []
        var live: Set<String> = ["m1", "m2"]
        /// What the relay answers next; nil: it takes the message.
        var answers: [Error?] = []
        let file = tempDir().appendingPathComponent("outbox.json")

        func outbox() -> Outbox {
            Outbox(file: file, now: { self.clock },
                   post: { o, _ in
                       if !self.answers.isEmpty, let e = self.answers.removeFirst() { throw e }
                       self.sent.append(o.id)
                   },
                   live: { self.live.contains($0) }, delivered: { self.delivered.append($0.id) },
                   wake: { self.wakes.append($0) }, clock: { self.clock }, random: { 0.5 })
        }

        func lock(_ id: String, _ machine: String = "m1", grant: GrantRecord? = nil) -> Outgoing {
            Outgoing(id: id, machine: machine, sealed: "sealed-\(id)", lock: true, made: clock, grant: grant)
        }

        func notice(_ id: String, _ machine: String = "m1") -> Outgoing {
            Outgoing(id: id, machine: machine, sealed: "sealed-\(id)", lock: false, made: clock)
        }

        func maintenance(_ secs: Int64) -> RelayError { .unavailable(until: clock + secs * 1000, status: 503, code: "maintenance") }
    }

    @Test func maintenanceKeepsItUntilRetryAfter() async {
        let s = Script()
        let box = s.outbox()
        s.answers = [s.maintenance(120)]
        #expect(await box.send(s.lock("a"), userTapped: false) == .queued)
        #expect(s.wakes == [120_000])
        s.clock += 60_000
        await box.flush()
        #expect(s.sent.isEmpty)
        #expect(s.wakes.last == 60_000)
        // What the app sends by itself meanwhile waits too, without a call.
        #expect(await box.send(s.notice("n"), userTapped: false) == .queued)
        #expect(s.sent.isEmpty)
        s.clock += 60_000
        await box.flush()
        #expect(s.sent == ["a", "n"])
        #expect(s.delivered == ["a", "n"])
        #expect(box.items.isEmpty)
    }

    @Test func noAnswerBacksOffDoublingAndTheWindowCounts() async {
        let s = Script()
        let box = s.outbox()
        s.answers = [RelayError.transport("offline")]
        _ = await box.send(s.notice("n"), userTapped: false)
        #expect(s.wakes.last == 10_000)
        s.clock += 10_000
        s.answers = [RelayError.http(status: 502, code: "http_502", body: .null)]
        await box.flush()
        #expect(s.wakes.last == 20_000)
        s.clock += 20_000
        s.answers = [RelayError.rateLimited(until: s.clock + 600_000, scope: "phone")]
        await box.flush()
        #expect(s.wakes.last == 600_000)
        s.clock += 600_000
        await box.flush()
        #expect(s.sent == ["n"])
    }

    @Test func aTappedLockGoesAtOnceAndCoversTheQueuedOne() async {
        let s = Script()
        let box = s.outbox()
        s.answers = [s.maintenance(120)]
        _ = await box.send(s.lock("a"), userTapped: false)
        #expect(await box.send(s.lock("b"), userTapped: true) == .sent)
        #expect(s.sent == ["b"])
        #expect(s.delivered == ["a"])
        #expect(box.items.isEmpty)
    }

    @Test func aNoticeWaitsBehindItsMachinesQueue() async {
        let s = Script()
        let box = s.outbox()
        s.answers = [RelayError.transport("offline")]
        _ = await box.send(s.notice("n1"), userTapped: false)
        s.clock += 10_000
        #expect(await box.send(s.lock("l"), userTapped: false) == .sent)
        #expect(await box.send(s.notice("n2"), userTapped: false) == .queued)
        await box.flush()
        #expect(s.sent == ["l", "n1", "n2"])
        #expect(await box.send(s.notice("n3", "m2"), userTapped: false) == .sent)
    }

    /// A notice sent while the one before it for the same machine is on its way waits behind it,
    /// also when that one fails.
    @Test func aNoticeSentWhileAnotherIsOnItsWayKeepsTheOrder() async {
        let s = Script()
        var gate: CheckedContinuation<Void, Never>?
        var first = true
        let box = Outbox(file: s.file, now: { s.clock },
                         post: { o, _ in
                             if first {
                                 first = false
                                 await withCheckedContinuation { gate = $0 }
                                 throw RelayError.transport("the response was lost")
                             }
                             s.sent.append(o.id)
                         },
                         live: { s.live.contains($0) }, delivered: { s.delivered.append($0.id) },
                         wake: { s.wakes.append($0) }, clock: { s.clock }, random: { 0.5 })
        let n1 = Task { await box.send(s.notice("n1"), userTapped: false) }
        while gate == nil { await Task.yield() }
        #expect(await box.send(s.notice("n2"), userTapped: false) == .queued)
        // A flush meanwhile leaves both: n1 is on its way, n2 waits for it.
        await box.flush()
        #expect(s.sent.isEmpty)
        gate?.resume()
        #expect(await n1.value == .queued)
        #expect(box.items.map(\.id) == ["n1", "n2"])
        s.clock += 10_000
        await box.flush()
        #expect(s.sent == ["n1", "n2"])
    }

    @Test func oneLockPerMachineKeepingItsAllowanceAcrossARestart() async {
        let s = Script()
        let g = GrantRecord(machine: "m1", placeId: "p1", at: 5, ends: 9, locked: false)
        // The first fails; the second waits out its backoff without a call.
        s.answers = [RelayError.transport("offline")]
        let box = s.outbox()
        _ = await box.send(s.lock("a", grant: g), userTapped: false)
        _ = await box.send(s.lock("b"), userTapped: false)
        #expect(box.items.map(\.id) == ["b"])
        let again = s.outbox()
        #expect(again.items.first?.grant == g)
        await again.flush()
        #expect(s.sent == ["b"])
        #expect(s.outbox().items.isEmpty)
    }

    @Test func finalAnswersAndObsoleteMessagesAreDropped() async {
        let s = Script()
        let box = s.outbox()
        s.answers = [RelayError.http(status: 404, code: "not_paired", body: .null)]
        #expect(await box.send(s.lock("a"), userTapped: false) == .refused)
        s.answers = [RelayError.transport("offline"), RelayError.transport("offline")]
        _ = await box.send(s.notice("n1"), userTapped: false)
        _ = await box.send(s.notice("n2", "m2"), userTapped: false)
        s.live = ["m2"]
        s.clock += Outbox.maxAgeMs + 1
        await box.flush()
        #expect(s.sent.isEmpty)
        #expect(box.items.isEmpty)
        #expect(!Outbox.isFinal(RelayError.http(status: 401, code: "bad_signature", body: .null)))
        #expect(Outbox.isFinal(RelayError.http(status: 403, code: "forbidden", body: .null)))
    }

    @Test func theCardAfterALock() {
        let at: Int64 = 1_795_266_000_000
        let marks = LockMarks.sent([:], "m", at: at, accepted: at)
        // An Open status made before the lock does not end it; one made after, or Locked, does.
        #expect(LockMarks.status(marks, "m", statusTime: at - 30_000, open: true) == marks)
        #expect(LockMarks.status(marks, "m", statusTime: at + 1_000, open: true).isEmpty)
        #expect(LockMarks.status(marks, "m", statusTime: at - 30_000, open: false).isEmpty)
        // Locked once the relay held it a minute with no status; never while it waits to go.
        let queued = LockMarks.sent([:], "m", at: at, accepted: 0)
        #expect(!LockMarks.settled(queued["m"]!, now: at + 3_600_000))
        let taken = LockMarks.accepted(queued, "m", now: at + 120_000)
        #expect(!LockMarks.settled(taken["m"]!, now: at + 179_999))
        #expect(LockMarks.settled(taken["m"]!, now: at + 180_000))
        #expect(LockMarks.pruned(taken, now: at + LockMarks.maxAgeMs) { _ in true }.isEmpty)
    }
}

#if os(macOS)
/// Locks and notices during the relay's maintenance (`503` with `Retry-After`), the corrected
/// clock on a phone whose clock is behind, and the card after a lock, against a fake relay and a
/// fake machine of the test's own (SPEC.md 8.1, 9.6, 11.8, 11.9).
@MainActor
@Suite(.enabled(if: relayBin != nil && machineBin != nil), .serialized, .timeLimit(.minutes(3)))
struct MaintenanceTests {
    func paired(_ relay: LocalRelay) async throws -> (AppEngine, FakeMachine, Machine) {
        let (engine, _, _) = try await makeEngine(relayURL: relay.url, places: StubPlaces())
        try await onboard(engine)
        let m = FakeMachine(relay: relay.url)
        let link = m.home.appendingPathComponent("link")
        let (code, out) = try m.run(["pair", "--name", "dev@mbp.example.com", "--no-wait", "--link-file", link.path])
        #expect(code == 0, "\(out)")
        let offer = try engine.parseOffer(try String(contentsOf: link, encoding: .utf8)).get()
        let machine = try await engine.pair(offer, replaces: nil).get()
        #expect(try m.run(["pair-wait", "--wait-secs", "20"]).0 == 0)
        return (engine, m, machine)
    }

    /// `503 maintenance` with `Retry-After: 1` on the next message, once.
    func maintenanceOnce(_ relay: LocalRelay) async throws {
        try await relay.control("/test/fail", #"{"status":503,"error":"maintenance","retryAfter":1,"path":"/messages"}"#)
    }

    func listen(_ m: FakeMachine, _ extra: [String] = []) async throws -> FakeMachine.Run {
        let run = try m.start(["listen", "--secs", "20", "--count", "1"] + extra)
        _ = try await run.find("(LISTENING)")
        return run
    }

    func eventually(_ done: () -> Bool) async throws -> Bool {
        for _ in 0..<200 where !done() { try await Task.sleep(for: .milliseconds(50)) }
        return done()
    }

    @Test func aLockDuringMaintenanceIsSentAfterRetryAfter() async throws {
        let relay = try await LocalRelay.start()
        defer { relay.stop() }
        let (engine, m, machine) = try await paired(relay)
        try await maintenanceOnce(relay)
        let run = try await listen(m)
        // Not taken now: kept, not dropped.
        #expect(await engine.lock(machine, reason: "phone") == false)
        #expect(engine.outbox.items.count == 1)
        #expect(MachineView.of(machine, engine).row == "Locking…")
        let (_, heard) = await m.waitAsync(run)
        #expect(heard.contains("type=lock"), "\(heard)")
        #expect(try await eventually { engine.outbox.items.isEmpty })
    }

    @Test func aNoticeDuringMaintenanceIsSentAfterRetryAfter() async throws {
        let relay = try await LocalRelay.start()
        defer { relay.stop() }
        let (engine, m, _) = try await paired(relay)
        try await maintenanceOnce(relay)
        let run = try await listen(m)
        await engine.sendNotice(what: "unseal_all", state: "pending", machine: nil, delayId: "d1", at: engine.clockNow() + 7_200_000)
        #expect(engine.outbox.items.count == 1)
        let (_, heard) = await m.waitAsync(run)
        #expect(heard.contains("type=notice"), "\(heard)")
        #expect(try await eventually { engine.outbox.items.isEmpty })
    }

    /// The phone's clock 3 minutes behind (the relay's and the machine's are right). The machine
    /// ignores a lock made over a minute before its session opened: on the phone's own clock a
    /// lock sent now would look made before the session; on the corrected clock it applies.
    @Test func aLockIsStampedOnTheCorrectedClock() async throws {
        let relay = try await LocalRelay.start()
        defer { relay.stop() }
        let (engine, m, machine) = try await paired(relay)
        let out = try await relay.control("/test/clock", #"{"offset": 180}"#)
        let relayNow = try #require((try JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any])?["time"] as? Int64) * 1000
        #expect(await engine.relay.relayTime() != nil)
        // The machine's session opened just now, by its own (right) clock.
        #expect(nowMs() + 60_000 < relayNow, "the phone's own clock would make the lock look old")
        let run = try await listen(m, ["--opened-at", "\(relayNow)"])
        #expect(await engine.lock(machine, userTapped: true))
        let (_, heard) = await m.waitAsync(run)
        #expect(heard.contains("type=lock") && heard.contains("applies=true"), "\(heard)")
    }

    /// Leaving the place while the relay is in maintenance: the lock for the machine allowed there
    /// is kept and sent after Retry-After, and its allowance is recorded as locked once it went.
    @Test func leavingThePlaceDuringMaintenanceLocksAfterRetryAfter() async throws {
        let relay = try await LocalRelay.start()
        defer { relay.stop() }
        let (engine, m, _) = try await paired(relay)
        await engine.apply(.addPlace(place: TrustedPlace(id: "p1", name: "Desk", lat: 0, lon: 0, radius: 150,
                                                         created: UInt64(nowMs() - 3 * 86_400_000), updated: 0,
                                                         deleted: false, manual: false)))
        await engine.onPlaceTransition(["p1"], entered: true)
        let r = try m.start(["request", "--kind", "open", "--subject", "secret:OPENAI_API_KEY", "--new-key", "secrets:store-1",
                             "--cmd", "npm test", "--ttl", "60"])
        var w: Waiting?
        for _ in 0..<300 where w == nil {
            await engine.catchUp()
            w = engine.waiting.first
            if w == nil { try await Task.sleep(for: .milliseconds(100)) }
        }
        let card = try #require(w, "no request: \(r.output)")
        #expect(await engine.answer(card.id, .allowSession))
        let (code, out) = await m.waitAsync(r)
        #expect(code == 0, "\(out)")
        #expect(engine.local.grants.first?.placeId == "p1")
        try await maintenanceOnce(relay)
        let run = try await listen(m)
        await engine.onPlaceTransition(["p1"], entered: false)
        let (_, heard) = await m.waitAsync(run)
        #expect(heard.contains("type=lock"), "\(heard)")
        #expect(try await eventually { engine.local.grants.first?.locked == true })
        #expect(engine.outbox.items.isEmpty)
    }

    /// After a lock the card says "Locking…": a status the machine made before the lock arrived,
    /// still Open, does not show the session as open again; a status saying Locked does.
    @Test func theCardShowsLockingUntilAStatusAnswersTheLock() async throws {
        let relay = try await LocalRelay.start()
        defer { relay.stop() }
        let (engine, m, machine) = try await paired(relay)
        #expect(try m.run(["status", "--state", "open", "--left", "3000"]).0 == 0)
        await engine.refreshStatus()
        #expect(MachineView.of(try #require(engine.machine(machine.key)), engine).state == .open)
        #expect(await engine.lock(machine, userTapped: true))
        #expect(MachineView.of(try #require(engine.machine(machine.key)), engine).row == "Locking…")
        #expect(try m.run(["status", "--state", "open", "--left", "3000", "--made-ago", "30"]).0 == 0)
        await engine.refreshStatus()
        #expect(MachineView.of(try #require(engine.machine(machine.key)), engine).row == "Locking…")
        #expect(try m.run(["status", "--state", "locked"]).0 == 0)
        await engine.refreshStatus()
        #expect(MachineView.of(try #require(engine.machine(machine.key)), engine).state == .locked)
        #expect(engine.lockMarks.isEmpty)
    }
}
#endif
