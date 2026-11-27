import Foundation
import Testing
import EngineKit
import Places
import SealCore
import UserNotifications
import Vault
@testable import Engine
@testable import Relay

/// The pace of a screen's relay checks, and what a notification button does when the app is
/// not up in time (SPEC.md 8.1, 10.2): rules that need no relay.
@Suite(.timeLimit(.minutes(1))) struct PacingUnitTests {
    let down = RelayError.transport("offline")

    @Test func errorsDoubleThePauseUpToTheCapAndAnAnswerResetsIt() {
        var b = PollBackoff(base: 5000, random: { 0.5 })
        #expect(b.after(nil, window: 0) == 5000)
        #expect(b.after(down, window: 0) == 10_000)
        #expect(b.after(RelayError.http(status: 503, code: "internal", body: .null), window: 0) == 20_000)
        #expect(b.after(down, window: 0) == 40_000)
        #expect(b.after(down, window: 0) == 60_000)
        for _ in 0..<20 { #expect(b.after(down, window: 0) == 60_000) }
        #expect(b.after(nil, window: 0) == 5000)
    }

    @Test func thePauseHasJitter() {
        var low = PollBackoff(base: 5000, random: { 0 })
        var high = PollBackoff(base: 5000, random: { 1 })
        #expect(low.after(down, window: 0) == 8000)
        #expect(high.after(down, window: 0) == 12_000)
    }

    @Test func theRateLimitWindowIsWaitedOut() {
        var b = PollBackoff(base: 5000, random: { 0.5 })
        #expect(b.after(RelayError.rateLimited(until: 0, scope: "phone"), window: 600_000) == 600_000)
        #expect(!b.stopped)
    }

    @Test func aFinalAnswerStopsTheChecks() {
        let finals: [RelayError] = [.http(status: 403, code: "forbidden", body: .null), .http(status: 400, code: "bad_id", body: .null),
                                    .http(status: 404, code: "gone", body: .null), .http(status: 401, code: "bad_signature", body: .null),
                                    .clockSkew, .noKeys]
        for e in finals {
            var b = PollBackoff(base: 5000)
            #expect(b.after(e, window: 0) == nil, "\(e)")
            #expect(b.stopped)
        }
        #expect(!PollBackoff.isFinal(RelayError.http(status: 408, code: "timeout", body: .null)))
        #expect(!PollBackoff.isFinal(RelayError.http(status: 500, code: "internal", body: .null)))
    }

    /// The kept window: none once passed, at most a day on (a clock set back).
    @Test func aKeptWindowStartsTheNextClientInsideIt() {
        let files = SharedFiles(root: tempDir())
        #expect(files.keptRateLimit(now: 1000) == 0)
        files.keepRateLimit(until: 5000)
        #expect(files.keptRateLimit(now: 2000) == 5000)
        #expect(files.keptRateLimit(now: 5000) == 0)
        files.keepRateLimit(until: .max)
        #expect(files.keptRateLimit(now: 2000) == 2000 + SharedFiles.keptWindowMs)
        files.removeAll()
        #expect(files.keptRateLimit(now: 2000) == 0)
    }

    /// A notification button pressed while the app could not start in time: its answer did
    /// not go, and the request's notification says so. A tap on the notification itself, or a
    /// dismissal, posts nothing (SPEC.md 10.2).
    @Test func aButtonTheAppCouldNotAnswerSaysSo() throws {
        let note = try #require(Notes.notActedOn(action: "ALLOW_ONCE", id: "r1"))
        #expect(note.id == "r1")
        #expect(note.content.title == Texts.requestTitle)
        #expect(note.content.body == Texts.answerNotSent)
        #expect(note.content.userInfo["id"] as? String == "r1")
        #expect(Notes.notActedOn(action: "DENY", id: "r1") != nil)
        #expect(Notes.notActedOn(action: UNNotificationDefaultActionIdentifier, id: "r1") == nil)
        #expect(Notes.notActedOn(action: UNNotificationDismissActionIdentifier, id: "r1") == nil)
        #expect(Notes.notActedOn(action: "ALLOW_ONCE", id: nil) == nil)
    }
}

/// The pauses a poll asked for, instead of sleeping.
final class Pauses: @unchecked Sendable {
    private let lock = NSLock()
    private var list: [Int64] = []
    var all: [Int64] { lock.withLock { list } }
    func add(_ p: Int64) -> Int { lock.withLock { list.append(p); return list.count } }
}

/// An erase that a stop cut short is finished at the next start (SPEC.md 11.19).
@MainActor
@Suite(.timeLimit(.minutes(1))) struct EraseTests {
    func place() -> TrustedPlace {
        TrustedPlace(id: "p1", name: "Desk", lat: 0, lon: 0, radius: 150, created: UInt64(nowMs()), updated: 0,
                     deleted: false, manual: false)
    }

    @Test func anEraseStoppedAfterTheKeysIsFinishedAtTheNextStart() async throws {
        let (engine, vault, _) = try await makeEngine()
        try await onboard(engine)
        await engine.apply(.addPlace(place: place()))
        #expect(!engine.state.places.isEmpty)
        // What a stop right after the keychain erase leaves: the marker, no keys, the database.
        engine.files.markErasing()
        await vault.erase()
        let next = await AppEngine(vault: vault, db: engine.db, config: engine.config, files: engine.files,
                                   notifier: RecordingNotifier(), places: nil)
        #expect(next.state.places.isEmpty)
        #expect(!engine.files.erasing)
    }

    @Test func anEraseLeavesNoMarker() async throws {
        let (engine, vault, _) = try await makeEngine()
        try await onboard(engine)
        await engine.apply(.addPlace(place: place()))
        await engine.erase(alsoBackup: false)
        #expect(!engine.files.erasing)
        #expect(await vault.readPhoneKeys() == nil)
        let next = await AppEngine(vault: vault, db: engine.db, config: engine.config, files: engine.files,
                                   notifier: RecordingNotifier(), places: nil)
        #expect(next.state.places.isEmpty)
    }

    /// An install that never erased keeps its database at start.
    @Test func aStartWithoutTheMarkerKeepsTheDatabase() async throws {
        let (engine, vault, _) = try await makeEngine()
        try await onboard(engine)
        await engine.apply(.addPlace(place: place()))
        let next = await AppEngine(vault: vault, db: engine.db, config: engine.config, files: engine.files,
                                   notifier: RecordingNotifier(), places: nil)
        #expect(next.state.places.count == 1)
        #expect(await vault.readPhoneKeys() != nil)
    }
}

#if os(macOS)
/// Calls the app makes by itself wait out the relay's rate-limit window; the person's taps do
/// not. The window outlives the extension's client. Leave's checks back off. A foreground that
/// ended before its socket opened opens none (SPEC.md 8.1, 8.3, 10.1, 11.22).
extension TimingTests {
    /// Opens a two-minute window on `engine`'s client with one refused call.
    func openWindow(_ engine: AppEngine, _ relay: LocalRelay) async throws {
        try await relay.control("/test/fail", #"{"path": "/machines", "status": 429, "error": "rate_limited", "retryAfter": 120}"#)
        _ = try? await engine.relay.machines()
        #expect(await engine.relay.rateLimitedForMs() > 100_000)
    }

    @Test func anAutomaticAnswerInsideTheWindowAsksThePerson() async throws {
        let relay = try await LocalRelay.start()
        defer { relay.stop() }
        let (engine, _, m) = try await paired(relay)
        let agentArgs = ["request", "--kind", "agent", "--agent", "claude", "--repo-id", "github.com/acme/shop",
                         "--names", "OPENAI_API_KEY", "--use", "claude:github.com/acme/shop:OPENAI_API_KEY",
                         "--subject", "secret:OPENAI_API_KEY", "--key", "secrets:store-1", "--cmd", "npm test"]
        var r = try m.start(agentArgs)
        let first = try await firstRequest(engine, r)
        #expect(await engine.answer(first.id, .allow))
        _ = await m.waitAsync(r)
        #expect(try m.run(["status", "--state", "open", "--left", "3600"]).0 == 0)
        await engine.refreshStatus()
        r = try m.start(agentArgs)
        var pending: RelayRequest?
        for _ in 0..<100 where pending == nil {
            pending = try? await engine.relay.requests().first
            if pending == nil { try await Task.sleep(for: .milliseconds(100)) }
        }
        let request = try #require(pending)
        try await openWindow(engine, relay)
        // It would answer by itself; inside the window that answer does not go out.
        await engine.handle(request, fromPush: false)
        let w = try #require(engine.waiting.first { $0.id == request.id }, "answered inside the window")
        #expect(w.verdict.asking == .oneTap)
        // The person's tap goes, window or not.
        #expect(await engine.answer(w.id, .allowOnce))
        let (code, out) = await m.waitAsync(r)
        #expect(code == 0, "\(out)")
    }

    @Test func aLockTheAppSendsByItselfWaitsOutTheWindowATappedOneGoes() async throws {
        let relay = try await LocalRelay.start()
        defer { relay.stop() }
        let (engine, _, _) = try await paired(relay)
        let machine = try #require(engine.liveMachines.first)
        try await openWindow(engine, relay)
        #expect(await engine.lock(machine, reason: "place") == false)
        #expect(await engine.lock(machine, userTapped: true))
    }

    /// The extension makes a client per push: a window one push got holds for the next push,
    /// and for the app (SPEC.md 10.1).
    @Test func theExtensionKeepsTheWindowBetweenPushes() async throws {
        let relay = try await LocalRelay.start()
        defer { relay.stop() }
        let (engine, _, m) = try await paired(relay)
        let r = try openRequest(m)
        var id: String?
        for _ in 0..<100 where id == nil {
            id = try? await engine.relay.requests().first?.id
            if id == nil { try await Task.sleep(for: .milliseconds(100)) }
        }
        let push = UNMutableNotificationContent()
        push.userInfo = ["type": "request", "id": try #require(id)]
        try await relay.control("/test/fail", #"{"path": "/requests", "status": 429, "error": "rate_limited", "retryAfter": 120}"#)
        #expect(await ExtensionHandler(vault: engine.vault, files: engine.files).handle(push) == nil)
        #expect(engine.files.keptRateLimit(now: nowMs()) > 100_000)
        // The next push: the relay would list the request now, but no call goes out.
        let again = UNMutableNotificationContent()
        again.userInfo = push.userInfo
        #expect(await ExtensionHandler(vault: engine.vault, files: engine.files).handle(again) == nil)
        // An app started now begins inside the same window.
        let next = await AppEngine(vault: engine.vault, db: engine.db, config: engine.config, files: engine.files,
                                   notifier: RecordingNotifier(), places: nil)
        #expect(await next.relay.rateLimitedForMs() > 100_000)
        r.process.terminate()
    }

    /// Leave's "Hand back each computer": a failing relay is asked less and less often, an
    /// answer brings back the 5 s, and a final answer stops the checks (SPEC.md 8.1, 11.22).
    @Test func handBackChecksBackOffAndStopOnAFinalAnswer() async throws {
        let relay = try await LocalRelay.start()
        defer { relay.stop() }
        let (engine, _, _) = try await paired(relay)
        try await relay.control("/test/fail", #"{"path": "/machines", "status": 503, "error": "internal", "times": 3}"#)
        let pauses = Pauses()
        await engine.pollHandBack(sleep: { pause in
            // After an answer, the relay refuses for good.
            if pauses.add(pause) == 4 {
                _ = try? await relay.control("/test/fail", #"{"path": "/machines", "status": 403, "error": "forbidden"}"#)
            }
        })
        let p = pauses.all
        #expect(p.count == 4, "\(p)")
        guard p.count == 4 else { return }
        #expect((8000...12_000).contains(p[0]))
        #expect((16_000...24_000).contains(p[1]))
        #expect((32_000...48_000).contains(p[2]))
        #expect((4000...6000).contains(p[3]))
    }

    /// The app left the foreground while `onForeground` was on its way: no socket opens, and
    /// the next foreground opens one (SPEC.md 8.3).
    @Test func aForegroundThatEndedOpensNoSocket() async throws {
        let relay = try await LocalRelay.start()
        defer { relay.stop() }
        let (engine, _, _) = try await paired(relay)
        engine.hooks.beforeSocket = { await engine.onBackground() }
        await engine.onForeground()
        #expect(engine.socket == nil)
        #expect(!engine.foreground)
        engine.hooks.beforeSocket = nil
        await engine.onForeground()
        #expect(engine.socket != nil)
        #expect(try await relay.untilPhoneSockets(1))
        await engine.onBackground()
        #expect(try await relay.untilPhoneSockets(0))
    }
}
#endif
