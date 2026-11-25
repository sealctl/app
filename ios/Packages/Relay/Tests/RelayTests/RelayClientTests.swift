import Foundation
import Testing
import SealCore
@testable import Relay

/// The relay client against the fake relay (`tools/fake-relay`). Set `SEALCTL_TEST_RELAY` to
/// its origin (CI starts it on 127.0.0.1:8787); without it these tests are skipped.
let testRelay = ProcessInfo.processInfo.environment["SEALCTL_TEST_RELAY"]

func fresh() throws -> PhoneKeys {
    PhoneKeys.fromRoot(root: Root.fromWords(words: try Words.generate()))
}

/// Unsigned test controls (`/test/...`, loopback only).
func control(_ path: String, _ body: JSON) async throws -> JSON {
    var req = URLRequest(url: URL(string: testRelay! + path)!)
    req.httpMethod = "POST"
    req.httpBody = body.data()
    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
    let (data, _) = try await URLSession.shared.data(for: req)
    return try JSON(data: data)
}

@Suite(.enabled(if: testRelay != nil), .serialized)
struct RelayClientTests {
    @Test func healthAndEmptyLists() async throws {
        let keys = try fresh()
        let c = RelayClient(baseURL: testRelay!, keys: { keys })
        let h = try await c.health()
        #expect(h["ok"].bool == true || !h.isNull)
        #expect(try await c.machines().isEmpty)
        #expect(try await c.requests().isEmpty)
        #expect(try await c.phoneId() == keys.publicId())
    }

    @Test func stateCompareAndSwap() async throws {
        let keys = try fresh()
        let c = RelayClient(baseURL: testRelay!, keys: { keys })
        let (rev0, blob0) = try await c.getState()
        #expect(blob0 == nil)
        let rev1 = try await c.putState(rev: rev0, blob: "AAAA")
        #expect(rev1 > rev0)
        await #expect(throws: RelayError.conflict(rev: rev1)) {
            _ = try await c.putState(rev: rev0, blob: "BBBB")
        }
        let (rev2, blob2) = try await c.getState()
        #expect(rev2 == rev1)
        #expect(blob2 == "AAAA")
    }

    @Test func pushDevices() async throws {
        let keys = try fresh()
        let c = RelayClient(baseURL: testRelay!, keys: { keys })
        let token = String(repeating: "ab", count: 32)
        let device = randomId()
        let n = try await c.putPush(device: device, platform: "apns", token: token, sandbox: true)
        #expect(n == 1)
        let list = try await c.listPush()
        #expect(list.first?.platform == "apns")
        #expect(list.first?.sandbox == true)
        try await c.deletePush(device)
        try await c.deletePush(device)  // unknown_device counts as done
        #expect(try await c.listPush().isEmpty)
    }

    /// Runs `body` with the relay's clock `secs` ahead, and puts it back before returning, also
    /// when `body` throws. A reset left to a `defer { Task { ... } }` could land after the next
    /// test had set its own offset (run 45603025961: `relayTimesReachTheClock` saw offset 0).
    func withRelayAhead(_ secs: Int, _ body: () async throws -> Void) async throws {
        _ = try await control("/test/clock", ["offset": .number(Double(secs))])
        do {
            try await body()
        } catch {
            _ = try? await control("/test/clock", ["offset": 0])
            throw error
        }
        _ = try await control("/test/clock", ["offset": 0])
    }

    @Test func clockSkewIsCorrectedOnce() async throws {
        let keys = try fresh()
        try await withRelayAhead(900) {
            let c = RelayClient(baseURL: testRelay!, keys: { keys })
            let machines = try await c.machines()
            #expect(machines.isEmpty)
            let offset = await c.clockOffsetSecs
            #expect(offset > 800)
        }
    }

    /// SPEC.md 8.1: the relay's time (health, `clock_skew`) and accepted signed times go to
    /// the corrected clock.
    @Test func relayTimesReachTheClock() async throws {
        let keys = try fresh()
        let seen = Seen()
        var system: Int64 = 0
        try await withRelayAhead(900) {
            let c = RelayClient(baseURL: testRelay!, keys: { keys },
                                onRelayTime: { t in Task { await seen.time(t) } },
                                onAccepted: { t in Task { await seen.accepted(t) } })
            let t = try #require(await c.relayTime())
            system = Int64(Date().timeIntervalSince1970 * 1000)
            #expect(abs(t - (system + 900_000)) < 5_000)
            let machines = try await c.machines()
            #expect(machines.isEmpty)
        }
        try await Task.sleep(nanoseconds: 200_000_000)
        let times = await seen.times
        let accepted = await seen.acceptedTimes
        // Health, then the `clock_skew` before the retry.
        #expect(times.count == 2)
        #expect(accepted.count == 1)
        #expect(abs(accepted[0] - (system + 900_000)) < 5_000)
    }

    @Test func rateLimitStopsCallsButNotTappedReplies() async throws {
        let keys = try fresh()
        let c = RelayClient(baseURL: testRelay!, keys: { keys })
        _ = try await control("/test/fail", ["status": 429, "error": "rate_limited", "retryAfter": 120, "scope": "phone"])
        do {
            _ = try await c.machines()
            Issue.record("no rate limit")
        } catch let e as RelayError {
            #expect(e.code == "rate_limited")
        }
        // Until retryAfter, calls stop without reaching the relay; the phone socket waits too.
        let left = await c.rateLimitedForMs()
        #expect(left > 110_000 && left <= 120_000)
        await #expect(throws: RelayError.self) { _ = try await c.requests() }
        // A reply the user taps still goes out (here: 404 gone, the relay was reached).
        do {
            try await c.reply(id: "nope", sealed: "x", userTapped: true)
        } catch let e as RelayError {
            #expect(e.code != "rate_limited")
        }
    }

    @Test func forcedErrorBodies() async throws {
        let keys = try fresh()
        let c = RelayClient(baseURL: testRelay!, keys: { keys })
        _ = try await control("/test/fail", ["status": 503, "error": "internal"])
        do {
            _ = try await c.machines()
            Issue.record("no error")
        } catch let e as RelayError {
            #expect(e.status == 503)
        }
        #expect(try await c.machines().isEmpty)
    }

    @Test func socketConnectsAndAnswersPong() async throws {
        let keys = try fresh()
        let c = RelayClient(baseURL: testRelay!, keys: { keys })
        let connected = Flag()
        let socket = PhoneSocket(client: c, onMessage: { _ in }, onConnected: { await connected.set() })
        await socket.start()
        for _ in 0..<50 where !(await connected.value) { try await Task.sleep(for: .milliseconds(100)) }
        #expect(await connected.value)
        #expect(await socket.isOpen)
        await socket.stop()
    }
}

actor Flag {
    var value = false
    func set() { value = true }
}

struct JSONNumberTests {
    @Test func relayNumbersOutOfRangeReadAsMissing() throws {
        let o = try JSON(data: Data(#"{"a": 1700000000000, "b": -1, "c": 1e20, "d": -1e300, "e": 2.9}"#.utf8))
        #expect(o["a"].int64 == 1_700_000_000_000)
        #expect(o["b"].int64 == -1)
        #expect(o["c"].int64 == nil)
        #expect(o["d"].long == 0)
        #expect(o["e"].int64 == 2)
    }
}

/// What a client reported, for the clock test.
actor Seen {
    var times: [Int64] = []
    var acceptedTimes: [Int64] = []
    func time(_ t: Int64) { times.append(t) }
    func accepted(_ t: Int64) { acceptedTimes.append(t) }
}
