import Foundation
import EngineKit
import Relay
import SealCore

/// A sealed `lock` or `notice` for one machine (SPEC.md 9.6, 11.9).
public struct Outgoing: Equatable, Sendable {
    public let id: String
    public let machine: String
    public let sealed: String
    public let lock: Bool
    /// Its `t`: when it was made, Unix ms on the corrected clock.
    public let made: Int64
    /// A lock for leaving a place: the allowance it locks, recorded as locked once the relay takes it.
    public var grant: GrantRecord?

    public init(id: String, machine: String, sealed: String, lock: Bool, made: Int64, grant: GrantRecord? = nil) {
        self.id = id; self.machine = machine; self.sealed = sealed; self.lock = lock; self.made = made; self.grant = grant
    }
}

/// Locks and notices the relay did not take (no answer, a `5xx` such as `503 maintenance`, a
/// `Retry-After`, the rate-limit window), kept in `file` and sent again until the relay takes
/// them or they no longer matter (SPEC.md 8.1, 9.6, 11.9): their machine is unpaired, the relay
/// gave a final answer (a `4xx` but `401`, `408` and `429`), or they are a day old (the relay
/// holds a message for a day, and no session outlasts one). A lock never waits behind anything:
/// the machine applies it whatever its order. A notice for a machine goes after those queued
/// before it, so the machine never sees a newer one first and drops the older as old.
///
/// `post` sends one message (tapped or the app's own); `delivered` hears of each the relay took
/// after it was queued; `wake` asks for `flush` again after that many ms. `now` is the corrected
/// clock; `clock` the system clock the waits are counted on.
@MainActor
final class Outbox {
    enum Result: Equatable {
        /// The relay took it.
        case sent
        /// Kept, and sent again later.
        case queued
        /// A final answer: not sent again.
        case refused
    }

    /// A message this old no longer matters: the relay holds one a day, and no session lasts longer.
    static let maxAgeMs: Int64 = 24 * 3_600_000

    private let file: URL?
    private let now: () -> Int64
    private let post: (Outgoing, Bool) async throws -> Void
    private let live: (String) -> Bool
    private let delivered: (Outgoing) -> Void
    private let wake: (Int64) -> Void
    private let clock: () -> Int64
    private let random: () -> Double
    private(set) var items: [Outgoing] = []
    /// Notices in `items` whose first try is on its way: the next one for their machine waits behind them.
    private var inFlight: Set<String> = []
    /// No try before this (system ms): a `Retry-After`, the rate-limit window, or the backoff.
    private var notBefore: Int64 = 0
    private var failures = 0
    private var flushing = false

    init(file: URL?, now: @escaping () -> Int64, post: @escaping (Outgoing, Bool) async throws -> Void,
         live: @escaping (String) -> Bool, delivered: @escaping (Outgoing) -> Void, wake: @escaping (Int64) -> Void,
         clock: @escaping () -> Int64 = { nowMs() }, random: @escaping () -> Double = { Double.random(in: 0...1) }) {
        self.file = file; self.now = now; self.post = post; self.live = live
        self.delivered = delivered; self.wake = wake; self.clock = clock; self.random = random
        if let file { items = Self.load(file) }
    }

    /// Sends `o` now, or queues it when the relay can't take it now. One the person tapped
    /// (`userTapped`, Lock now) is tried at once, whatever the wait; the app's own waits out a
    /// `Retry-After` or the rate-limit window in the queue.
    func send(_ o: Outgoing, userTapped: Bool) async -> Result {
        let behind = !o.lock && items.contains { $0.machine == o.machine }
        if behind || (!userTapped && clock() < notBefore) {
            enqueue(o)
            if behind { wake(max(0, notBefore - clock())) }
            return .queued
        }
        // A notice holds its place while it goes: one sent meanwhile for its machine waits behind
        // it, and if it fails it is sent again first.
        if !o.lock {
            items.append(o)
            inFlight.insert(o.id)
            save()
        }
        do {
            try await post(o, userTapped)
        } catch {
            inFlight.remove(o.id)
            if Self.isFinal(error) {
                remove(o.id)
                return .refused
            }
            // A notice is already in its place.
            if o.lock { enqueue(o) }
            failed(error)
            return .queued
        }
        if !o.lock {
            inFlight.remove(o.id)
            remove(o.id)
        }
        // A lock made later covers every session one queued earlier would lock.
        if o.lock { for old in removeLocks(o.machine) { delivered(old) } }
        // The relay is back: what waits goes now.
        failures = 0
        notBefore = 0
        if !items.isEmpty { wake(0) }
        return .sent
    }

    /// Sends what is waiting, oldest first, unless the last failure's wait is not over. Drops what
    /// no longer matters. Stops at the first failure and asks to be woken when its wait is over.
    func flush() async {
        guard !flushing else { return }
        flushing = true
        defer { flushing = false }
        dropObsolete()
        let wait = notBefore - clock()
        if wait > 0 {
            if !items.isEmpty { wake(wait) }
            return
        }
        // Machines with a notice on its way: their later notices wait for it.
        var busy: Set<String> = []
        for o in items {
            if inFlight.contains(o.id) { busy.insert(o.machine); continue }
            if !o.lock && busy.contains(o.machine) { continue }
            do {
                try await post(o, false)
            } catch {
                if Self.isFinal(error) { remove(o.id); continue }
                failed(error)
                return
            }
            remove(o.id)
            delivered(o)
        }
        failures = 0
        notBefore = 0
    }

    /// Forgets everything (erase).
    func clear() {
        items = []
        notBefore = 0
        failures = 0
        save()
    }

    /// An answer the same message would get again: a `4xx` but `401` (a clock the relay refused
    /// may be set right), `408` and `429`.
    static func isFinal(_ error: Error) -> Bool {
        guard let e = error as? RelayError else { return false }
        switch e {
        case .http, .conflict: return (400..<500).contains(e.status) && ![401, 408, 429].contains(e.status)
        default: return false
        }
    }

    /// The wait after `failures` failures that gave no `Retry-After`: 10 s doubling, at most 10
    /// minutes, ±20 %.
    static func backoffMs(_ failures: Int, random: () -> Double) -> Int64 {
        let base = min(Int64(10_000) << Int64(min(max(failures - 1, 0), 6)), 10 * 60_000)
        return Int64(Double(base) * (0.8 + 0.4 * random()))
    }

    private func failed(_ error: Error) {
        failures += 1
        var until: Int64 = 0
        switch error as? RelayError {
        case .unavailable(let u, _, _)?: until = u
        case .rateLimited(let u, _)?: until = u
        default: break
        }
        // The relay said when: then, not before and not later. Otherwise back off.
        notBefore = until > 0 ? until : clock() + Self.backoffMs(failures, random: random)
        wake(notBefore - clock())
    }

    private func enqueue(_ o: Outgoing) {
        var item = o
        if o.lock {
            // One lock per machine: the newer one covers the older, and keeps its allowance.
            let old = items.filter { $0.lock && $0.machine == o.machine }
            if o.grant == nil, let g = old.last(where: { $0.grant != nil })?.grant { item.grant = g }
            items.removeAll { $0.lock && $0.machine == o.machine }
        }
        items.append(item)
        save()
    }

    private func removeLocks(_ machine: String) -> [Outgoing] {
        let old = items.filter { $0.lock && $0.machine == machine }
        if !old.isEmpty {
            items.removeAll { $0.lock && $0.machine == machine }
            save()
        }
        return old
    }

    private func remove(_ id: String) {
        let before = items.count
        items.removeAll { $0.id == id }
        if items.count != before { save() }
    }

    private func dropObsolete() {
        let t = now()
        let before = items.count
        items.removeAll { !live($0.machine) || t - $0.made > Self.maxAgeMs }
        if items.count != before { save() }
    }

    // MARK: the file

    private struct Stored: Codable {
        var id, machine, sealed: String
        var lock: Bool
        var made: Int64
        var grantMachine: String?
        var grantPlace: String?
        var grantAt: UInt64?
        var grantEnds: UInt64?
    }

    private func save() {
        guard let file else { return }
        let stored = items.map {
            Stored(id: $0.id, machine: $0.machine, sealed: $0.sealed, lock: $0.lock, made: $0.made,
                   grantMachine: $0.grant?.machine, grantPlace: $0.grant?.placeId, grantAt: $0.grant?.at, grantEnds: $0.grant?.ends)
        }
        guard let data = try? JSONEncoder().encode(stored) else { return }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    private static func load(_ file: URL) -> [Outgoing] {
        guard let data = try? Data(contentsOf: file), let stored = try? JSONDecoder().decode([Stored].self, from: data) else { return [] }
        return stored.map { s in
            let grant = s.grantMachine.map {
                GrantRecord(machine: $0, placeId: s.grantPlace, at: s.grantAt ?? 0, ends: s.grantEnds ?? 0, locked: false)
            }
            return Outgoing(id: s.id, machine: s.machine, sealed: s.sealed, lock: s.lock, made: s.made, grant: grant)
        }
    }
}

/// A lock this phone sent to a machine whose status has not answered it yet (SPEC.md 11.8): `at`
/// is the lock's `t` (corrected clock), `accepted` when the relay took it, system ms (0 while it
/// waits in the outbox).
public struct LockMark: Codable, Equatable, Sendable {
    public var at: Int64
    public var accepted: Int64
}

/// The locks sent and not yet answered by a status, by machine (SPEC.md 11.8). The machine's card
/// shows "Locking…" from the lock until a status confirms it, and "Locked" once the relay has
/// held the lock for `settleMs` with no status. A status that says Locked ends the mark; one that
/// says Open ends it only when made after the lock (a session opened since): one the machine made
/// before it received the lock must not show the session as open again.
public enum LockMarks {
    /// How long after the relay took a lock with no status the card shows Locked.
    public static let settleMs: Int64 = 60_000
    /// A mark this old is dropped: the relay holds a message a day.
    public static let maxAgeMs: Int64 = 24 * 3_600_000

    public static func sent(_ marks: [String: LockMark], _ machine: String, at: Int64, accepted: Int64) -> [String: LockMark] {
        var m = marks
        m[machine] = LockMark(at: at, accepted: accepted)
        return m
    }

    /// After the relay took a queued lock for `machine` at `now`.
    public static func accepted(_ marks: [String: LockMark], _ machine: String, now: Int64) -> [String: LockMark] {
        guard var mark = marks[machine], mark.accepted == 0 else { return marks }
        mark.accepted = now
        var m = marks
        m[machine] = mark
        return m
    }

    /// After a status `machine` made at `statusTime` (its `t`): one that says it is not `open`
    /// confirms the lock; one that says Open counts only when made after the lock.
    public static func status(_ marks: [String: LockMark], _ machine: String, statusTime: Int64, open: Bool) -> [String: LockMark] {
        guard let mark = marks[machine], !open || statusTime >= mark.at else { return marks }
        var m = marks
        m[machine] = nil
        return m
    }

    /// Without those too old to matter at `now`, or for machines no longer paired.
    public static func pruned(_ marks: [String: LockMark], now: Int64, live: (String) -> Bool) -> [String: LockMark] {
        marks.filter { live($0.key) && now - $0.value.at < maxAgeMs }
    }

    /// Whether the card shows Locked rather than Locking… at `now` (system ms).
    public static func settled(_ mark: LockMark, now: Int64) -> Bool {
        mark.accepted != 0 && now - mark.accepted >= settleMs
    }
}
