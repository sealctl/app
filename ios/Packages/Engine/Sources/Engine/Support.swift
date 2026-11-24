import Foundation
import EngineKit
import Places
import SealCore
import UserNotifications

public typealias AppState = SealCore.State
public typealias AppSettings = SealCore.Settings

/// The local database on a serial executor (SPEC.md 6.3): every Rust `Store` call runs here.
public actor Database {
    let store: Store

    public init(path: String) throws {
        store = try Store.open(path: path)
    }

    public func run<T: Sendable>(_ f: @Sendable (Store) throws -> T) rethrows -> T {
        try f(store)
    }

    // The corrected clock (SPEC.md 8.1), read where an answer can't wait for this executor
    // (a screen's text, the decide context). The store guards itself: its calls are
    // serialised by its own lock, so these need not run here.

    /// The corrected clock, or the system clock when the store can't be read.
    public nonisolated func clockNow() -> ClockNow {
        (try? store.clockNow()) ?? ClockNow(now: UInt64(max(0, nowMs())), fresh: false)
    }

    /// The relay's time, Unix ms, as the relay gave it just now.
    public nonisolated func relayTime(_ ms: Int64) { _ = try? store.relayTime(relayMs: UInt64(max(0, ms))) }

    /// The relay accepted a call signed at `ms` (Unix ms).
    public nonisolated func relayAccepted(_ ms: Int64) { try? store.relayAccepted(signedMs: UInt64(max(0, ms))) }

    /// The relay's time last learned, for the extension's snapshot.
    public nonisolated func relayClock() -> RelayClock? { try? store.relayClock() }
}

/// Posting and removing notifications. The app uses `UNUserNotificationCenter`; the engine's
/// tests on a Mac record what would have shown.
@MainActor
public protocol Notifier: AnyObject {
    func post(id: String, content: UNNotificationContent, at: Date?) async
    func remove(ids: [String]) async
    /// Removes delivered request notifications whose `expires` has passed or that were answered.
    func removeStale(now: Int64, answered: Set<String>) async
    func allowed() async -> Bool
    func setBadge(_ n: Int) async
}

public extension Notifier {
    func post(id: String, content: UNNotificationContent) async { await post(id: id, content: content, at: nil) }
}

/// The places a decision needs and the fix at a first approval (implemented by `Places`).
@MainActor
public protocol PlacesProvider: AnyObject {
    var hasForeground: Bool { get }
    var hasAlways: Bool { get }
    var undetermined: Bool { get }
    func requestWhenInUse() async
    func requestAlways() async
    func monitor(_ fences: [Fence], onTransition: @escaping @Sendable ([String], Bool?) async -> Void) async
    func sample() async -> Fix?
}

extension Places: PlacesProvider {}

/// Build settings the engine needs.
public struct EngineConfig: Sendable {
    public var relayURL: String
    /// Debug builds only: shortens the level 3 delay for tests (0: the real hour).
    public var testDelaySecs: Int
    /// APNs development environment.
    public var sandboxPush: Bool
    public var version: String
    public var build: String

    public init(relayURL: String, testDelaySecs: Int = 0, sandboxPush: Bool = true, version: String = "1.0.0", build: String = "1") {
        self.relayURL = relayURL
        self.testDelaySecs = testDelaySecs
        self.sandboxPush = sandboxPush
        self.version = version
        self.build = build
    }
}

/// The app's phases (SPEC.md 6.1).
public enum Phase: Equatable, Sendable {
    case loading
    case needsScreenLock
    case noWords
    case backupFound(fingerprint: String, created: Int64)
    /// Keychain items survived a reinstall (7.4): "Continue with seed 7Hq3".
    case reinstalled
    case cardUnchecked
    case onboarding(step: Int)
    case ready
    /// The root is gone (passcode removed), or another phone changed or removed the words.
    case wordsLost(reason: WordsLostReason)
}

public enum WordsLostReason: Equatable, Sendable {
    case passcodeRemoved
    case removedElsewhere
}

/// Banners on the Machines tab (SPEC.md 11.20).
public struct Banners: Equatable, Sendable {
    public var offline = false
    public var relayDown = false
    public var rateLimitedUntil: Int64 = 0
    public var clockSkew = false
    public var signatureRefused = false
    public init() {}
}

/// A short confirmation after an answer (SPEC.md 11.7 "After an answer").
public struct Toast: Equatable, Identifiable, Sendable {
    public let id = UUID()
    public let text: String
}

/// Runs async work one at a time on the main actor (the approval path, SPEC.md 9.1).
@MainActor
final class SerialQueue {
    private var tail: Task<Void, Never>?

    func run(_ op: @escaping @MainActor () async -> Void) async {
        let prev = tail
        let t = Task { @MainActor in
            await prev?.value
            await op()
        }
        tail = t
        await t.value
    }
}

func utcOffset() -> Int32 { Int32(TimeZone.current.secondsFromGMT()) }
