import Foundation
import Testing
import EngineKit
import Places
import SealCore
import Vault
@testable import Engine
@testable import Relay

/// Holds the first caller at a hook until the test lets it go, so two events happen in a set
/// order. Later callers only count.
@MainActor
final class Gate {
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var open = false
    private(set) var entered = 0

    func wait() async {
        entered += 1
        if open || entered > 1 { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        open = true
        waiters.forEach { $0.resume() }
        waiters = []
    }

    func untilEntered(_ n: Int = 1) async throws {
        for _ in 0..<500 where entered < n { try await Task.sleep(for: .milliseconds(10)) }
        if entered < n { throw CancellationError() }
    }
}

/// Engine-level answers that need nothing from a relay.
@MainActor
@Suite struct TimingUnitTests {
    /// The phone's clock may be ahead of the relay's (up to the relay's 5-minute window, which
    /// raises no error): the request still gets its whole lifetime on this phone (SPEC.md 8.5).
    @Test func deadlineOnThePhonesClock() {
        // Clocks agree: the relay's `expires`.
        #expect(Waiting.deadline(seenAt: 10_000, created: 9_900, expires: 70_000) == 70_100)
        // Phone 2 minutes ahead: seen "after" it expired by the relay's clock.
        #expect(Waiting.deadline(seenAt: 200_000, created: 80_000, expires: 140_000) == 260_000)
        // Phone behind the relay: the relay's `expires`, which the relay enforces anyway.
        #expect(Waiting.deadline(seenAt: 10_000, created: 50_000, expires: 110_000) == 110_000)
        // Never more than the relay's clock window past `expires`.
        #expect(Waiting.deadline(seenAt: 10_000_000, created: 0, expires: 60_000) == 60_000 + 300_000)
    }

    /// A delayed action on the phone cancelled from a computer: the "Ready" note scheduled for
    /// its end is taken back, however the cancel arrived (SPEC.md 10.1, 11.23).
    @Test func cancelledDelayTakesBackTheReadyNote() async throws {
        let (engine, _, notifier) = try await makeEngine()
        try await onboard(engine)
        let now = UInt64(nowMs())
        await engine.applyLocal(.putDelayed(action: DelayedAction(
            id: "d1", what: "leave", machine: nil, releaseAt: now + 7_200_000, expires: now + 8_100_000,
            state: "waiting", cancelledBy: nil)))
        await engine.onSocketMessage(["type": "cancelled", "id": "d1", "by": "m1"])
        #expect(engine.local.delayed.first { $0.id == "d1" }?.state == "cancelled")
        #expect(notifier.removed.contains("ready-d1"))
    }
}

#if os(macOS)
/// Orders of events around one request, each against a fake relay of the test's own and a fake
/// machine (SPEC.md 8.5, 9.1, 11.7, 11.9, 11.22): answers racing each other and the expiry, a
/// phone clock ahead of the relay's, a failed reply, a socket request during a slow list,
/// leaving a place while an answer is on its way, and Leave after the relay data is gone.
@MainActor
@Suite(.enabled(if: relayBin != nil && machineBin != nil), .serialized)
struct TimingTests {
    func paired(_ relay: LocalRelay, places: PlacesProvider? = nil) async throws -> (AppEngine, RecordingNotifier, FakeMachine) {
        let (engine, _, notifier) = try await makeEngine(relayURL: relay.url, places: places)
        try await onboard(engine)
        let m = FakeMachine(relay: relay.url)
        let link = m.home.appendingPathComponent("link")
        let (code, out) = try m.run(["pair", "--name", "dev@mbp.example.com", "--no-wait", "--link-file", link.path])
        #expect(code == 0, "\(out)")
        let offer = try engine.parseOffer(try String(contentsOf: link, encoding: .utf8)).get()
        _ = try await engine.pair(offer, replaces: nil).get()
        #expect(try m.run(["pair-wait", "--wait-secs", "20"]).0 == 0)
        return (engine, notifier, m)
    }

    /// The first request on the phone, waiting or not.
    func firstRequest(_ engine: AppEngine, _ run: FakeMachine.Run) async throws -> Waiting {
        for _ in 0..<100 {
            await engine.catchUp()
            if let w = engine.waiting.first { return w }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw RelayError.transport("no request arrived: \(run.output)")
    }

    func openRequest(_ m: FakeMachine, ttl: Int = 60) throws -> FakeMachine.Run {
        try m.start(["request", "--kind", "open", "--subject", "secret:OPENAI_API_KEY", "--new-key", "secrets:store-1",
                     "--cmd", "npm test", "--ttl", "\(ttl)"])
    }

    /// A reply the relay refuses (here a 503 that stays) shows "Couldn't send your answer — try
    /// again." and keeps the card with its buttons; the next tap answers.
    @Test func failedAnswerSaysSoAndKeepsTheCard() async throws {
        let relay = try await LocalRelay.start()
        defer { relay.stop() }
        let (engine, _, m) = try await paired(relay)
        let r = try openRequest(m)
        let w = try await firstRequest(engine, r)
        try await relay.control("/test/fail", #"{"path": "/reply", "status": 400, "error": "bad_sealed"}"#)
        // The card's timer runs out while that answer is on its way: its task is over (stopped
        // here, not waited for), and what it does then is run by hand.
        let timer = try #require(engine.expiryTasks[w.id])
        engine.hooks.beforeReply = { id in
            timer.cancel()
            await timer.value
            await engine.expire(id)
        }
        #expect(!(await engine.answer(w.id, .allowOnce)))
        engine.hooks.beforeReply = nil
        #expect(engine.toast?.text == Texts.answerNotSent)
        #expect(engine.waiting.contains { $0.id == w.id && !$0.expired })
        // The timer is set again for the card that stays: a new one, as that one is over.
        let again = try #require(engine.expiryTasks[w.id])
        #expect(again != timer && !again.isCancelled)
        #expect(await engine.answer(w.id, .allowOnce))
        let (code, out) = await m.waitAsync(r)
        #expect(code == 0, "\(out)")
    }

    /// The same failure from a notification action: the request's notification comes back with
    /// that text, so the person can try again from it (SPEC.md 10.1).
    @Test func failedNotificationActionShowsTheRequestAgain() async throws {
        let relay = try await LocalRelay.start()
        defer { relay.stop() }
        let (engine, notifier, m) = try await paired(relay)
        let r = try openRequest(m)
        let w = try await firstRequest(engine, r)
        try await relay.control("/test/fail", #"{"path": "/reply", "status": 400, "error": "bad_sealed"}"#)
        let before = notifier.posted.filter { $0.0 == w.id }.count
        await engine.answerFromNotification(w.id, action: "ALLOW_ONCE")
        #expect(notifier.posted.filter { $0.0 == w.id }.count == before + 1)
        #expect(notifier.bodies.last == Texts.answerNotSent)
        #expect(engine.waiting.contains { $0.id == w.id && !$0.expired })
        r.process.terminate()
    }

    /// A notification action and a card button at once: the first answer goes, the second does
    /// nothing (SPEC.md 8.5: a reply is sent once per request).
    @Test func twoAnswersAtOnceSendOne() async throws {
        let relay = try await LocalRelay.start()
        defer { relay.stop() }
        let (engine, notifier, m) = try await paired(relay)
        let r = try openRequest(m)
        let w = try await firstRequest(engine, r)
        let gate = Gate()
        engine.hooks.beforeReply = { _ in await gate.wait() }
        let first = Task { await engine.answer(w.id, .allowOnce) }
        try await gate.untilEntered()
        let posted = notifier.posted.count
        #expect(!(await engine.answer(w.id, .allowSession)))
        await engine.answerFromNotification(w.id, action: "ALLOW_SESSION")
        // Neither one touched the answer on its way: no "try again" on the card or in a
        // notification, and the card keeps the request that answer was sealed from.
        #expect(engine.toast == nil)
        #expect(notifier.posted.count == posted)
        #expect(engine.waiting.first { $0.id == w.id }?.request === w.request)
        gate.release()
        #expect(await first.value)
        let (code, out) = await m.waitAsync(r)
        #expect(code == 0, "\(out)")
        #expect(out.contains("KEY secrets:store-1"))
        #expect(gate.entered == 1)
    }

    /// The expiry timer fires while the answer is on its way and the relay takes it: one
    /// answer is recorded, not also an expiry, and the card goes as answered.
    @Test func expiryDuringAnAnswerKeepsTheAnswer() async throws {
        let relay = try await LocalRelay.start()
        defer { relay.stop() }
        let (engine, _, m) = try await paired(relay)
        let r = try openRequest(m)
        let w = try await firstRequest(engine, r)
        engine.hooks.beforeReply = { id in await engine.expire(id) }
        #expect(await engine.answer(w.id, .allowOnce))
        let (code, out) = await m.waitAsync(r)
        #expect(code == 0, "\(out)")
        let log = await engine.usage(machine: nil)
        #expect(!log.contains { $0.outcome == "expired" }, "\(log.map(\.outcome))")
        #expect(log.filter { $0.outcome == "once" }.count == 1)
        #expect(engine.toast?.text == "Allowed once")
        #expect(!engine.waiting.contains { $0.id == w.id })
    }

    /// The phone's clock two minutes ahead of the relay's (inside the relay's window, so no
    /// clock error): a one-minute request is still open on the phone and its answer goes.
    @Test func phoneClockAheadOfTheRelay() async throws {
        let relay = try await LocalRelay.start()
        defer { relay.stop() }
        let (engine, _, m) = try await paired(relay)
        try await relay.control("/test/clock", #"{"offset": -120}"#)
        let r = try openRequest(m, ttl: 60)
        let w = try await firstRequest(engine, r)
        #expect(!w.expired)
        #expect(!(engine.waiting.first { $0.id == w.id }?.expired ?? true))
        #expect(await engine.answer(w.id, .allowOnce))
        let (code, out) = await m.waitAsync(r)
        #expect(code == 0, "\(out)")
    }

    /// The card's timer did not run (a late timer, a resumed process): a tap after the
    /// deadline closes the card as stopped waiting instead of doing nothing.
    @Test func answerAfterTheDeadlineClosesTheCard() async throws {
        let relay = try await LocalRelay.start()
        defer { relay.stop() }
        let (engine, _, m) = try await paired(relay)
        let r = try openRequest(m, ttl: 2)
        let w = try await firstRequest(engine, r)
        engine.expiryTasks[w.id]?.cancel()
        try await Task.sleep(for: .milliseconds(2_600))
        #expect(!(await engine.answer(w.id, .allowOnce)))
        #expect(engine.waiting.first { $0.id == w.id }?.expired == true)
        #expect(engine.toast == nil)
        _ = await m.waitAsync(r)
    }

    /// A request that comes by the socket while a slow request list is on its way is not
    /// closed as gone because that older list lacks it.
    @Test func socketRequestDuringASlowListStays() async throws {
        let relay = try await LocalRelay.start()
        defer { relay.stop() }
        let (engine, _, m) = try await paired(relay)
        var run: FakeMachine.Run?
        var once = false
        engine.hooks.afterRequestList = {
            guard !once else { return }
            once = true
            run = try? self.openRequest(m)
            for _ in 0..<100 {
                if let r = try? await engine.relay.requests().first {
                    await engine.handle(r, fromPush: false)
                    break
                }
                try? await Task.sleep(for: .milliseconds(100))
            }
            try? await Task.sleep(for: .milliseconds(2_200))
        }
        await engine.catchUp()
        let w = try #require(engine.waiting.first)
        #expect(!w.expired)
        run?.process.terminate()
    }

    /// The phone leaves the trusted place while an Allow made there is on its way: the lock
    /// that leaving sends must reach the machine after that answer (SPEC.md 11.9).
    @Test func leavingThePlaceDuringAnAnswerLocksAfterIt() async throws {
        let relay = try await LocalRelay.start()
        defer { relay.stop() }
        let (engine, _, m) = try await paired(relay, places: StubPlaces())
        await engine.apply(.addPlace(place: TrustedPlace(id: "p1", name: "Desk", lat: 0, lon: 0, radius: 150,
                                                         created: UInt64(nowMs() - 3 * 86_400_000), updated: 0,
                                                         deleted: false, manual: false)))
        await engine.onPlaceTransition(["p1"], entered: true)
        #expect(engine.placeKind() == .trusted)
        let r = try openRequest(m)
        let w = try await firstRequest(engine, r)
        #expect(w.verdict.asking == .oneTap)
        let listen = try m.start(["listen", "--secs", "8", "--count", "1"])
        try await Task.sleep(for: .milliseconds(300))
        engine.hooks.beforeReply = { _ in await engine.onPlaceTransition(["p1"], entered: false) }
        #expect(await engine.answer(w.id, .allowSession))
        let (code, out) = await m.waitAsync(r)
        #expect(code == 0, "\(out)")
        let (_, heard) = await m.waitAsync(listen)
        #expect(heard.contains("lock"), "\(heard)")
    }

    /// Leave sealctl after step 5: the relay data is gone, and coming back to the app does not
    /// register this phone's push device again (SPEC.md 11.22).
    @Test func noPushRegistrationAfterTheRelayDataIsDeleted() async throws {
        let relay = try await LocalRelay.start()
        defer { relay.stop() }
        let (engine, _, _) = try await paired(relay)
        await engine.setLeave(step: 5, skipped: [])
        #expect(await engine.leaveDeleteEverything())
        await engine.setLeave(step: 6, skipped: [])
        await engine.registerPush(token: String(repeating: "ab", count: 32))
        #expect(try await engine.relay.listPush().isEmpty)
    }
}
#endif
