import Foundation
import SealCore

/// What the Notification Service Extension needs, written by the app to the app group after
/// every change, atomically (SPEC.md 6.4). The extension never opens the database.
public struct ExtensionSnapshot: Codable, Sendable {
    public struct Day: Codable, Sendable {
        public var machine: String
        public var firstApproval: UInt64
        public var placeId: String?
        public var ends: UInt64
    }

    public struct HoldRecord: Codable, Sendable {
        public var machine: String
        public var until: UInt64
    }

    public struct Plan: Codable, Sendable {
        public var machine: String
        public var requestId: String
        public var planHash: String
        public var keys: [[String]]
        public var notBefore: UInt64
        public var state: String
        public var delayId: String?
        public var all: Bool
    }

    /// `encode_state` of the relay state: machines, answers, places.
    public var state: Data
    public var days: [Day]
    public var holds: [HoldRecord]
    public var plans: [Plan]
    public var currentPlace: String?
    public var placesOn: Bool
    public var relay: String
    public var written: Int64
    /// The relay's time the app last learned (SPEC.md 8.1); nil in a snapshot written before it.
    public var clock: Clock?
    /// Ids of the delayed actions whose kind this install knows: started here, or for a machine.
    /// A `delayed` push for any other phone-only record was started on another install (11.23).
    /// Nil in a snapshot written before it.
    public var knownDelayed: [String]?

    /// `RelayClock` as the snapshot keeps it.
    public struct Clock: Codable, Sendable {
        public var relay: UInt64
        public var boot: UInt64
        public var bootId: String
        public var distrusted: Bool
    }

    public init(state: State, local: LocalState, currentPlace: String?, placesOn: Bool, relay: String,
                clock: RelayClock? = nil) {
        self.state = encodeState(state: state)
        days = local.days.map { Day(machine: $0.machine, firstApproval: $0.firstApproval, placeId: $0.placeId, ends: $0.ends) }
        holds = local.holds.map { HoldRecord(machine: $0.machine, until: $0.until) }
        plans = local.plans.map {
            Plan(machine: $0.machine, requestId: $0.requestId, planHash: $0.planHash, keys: $0.keys.map { [$0.purpose, $0.id] },
                 notBefore: $0.notBefore, state: $0.state, delayId: $0.delayId, all: $0.all)
        }
        knownDelayed = local.delayed.filter { $0.what != Texts.otherDevice }.map(\.id)
        self.currentPlace = currentPlace
        self.placesOn = placesOn
        self.relay = relay
        written = nowMs()
        self.clock = clock.map { Clock(relay: $0.relay, boot: $0.boot, bootId: $0.bootId, distrusted: $0.distrusted) }
    }

    /// The relay's time the app last learned, as the core takes it.
    public var relayClock: RelayClock {
        guard let c = clock else { return RelayClock(relay: 0, boot: 0, bootId: "", distrusted: false) }
        return RelayClock(relay: c.relay, boot: c.boot, bootId: c.bootId, distrusted: c.distrusted)
    }

    public func decodedState() -> State? { try? decodeState(bytes: state) }

    public func day(_ machine: String) -> DayRecord? {
        days.first { $0.machine == machine }.map {
            DayRecord(machine: $0.machine, firstApproval: $0.firstApproval, placeId: $0.placeId, ends: $0.ends)
        }
    }

    public func hold(_ machine: String) -> Hold? {
        holds.first { $0.machine == machine }.map { Hold(machine: $0.machine, until: $0.until) }
    }

    public func plan(_ machine: String) -> PlanApprovalRecord? {
        plans.filter { $0.machine == machine && $0.state != "cancelled" }.max { $0.notBefore < $1.notBefore }.map {
            PlanApprovalRecord(machine: $0.machine, requestId: $0.requestId, planHash: $0.planHash, items: [],
                               keys: $0.keys.map { KeyRefRecord(purpose: $0[0], id: $0[1]) }, notBefore: $0.notBefore,
                               state: $0.state, delayId: $0.delayId, all: $0.all)
        }
    }
}

/// A request the extension answered by itself; the app records it at launch (SPEC.md 6.4).
public struct InboxItem: Codable, Sendable {
    public var id: String
    public var machine: String
    public var sealed: String
    public var outcome: String
    public var allowed: Bool
    public var placeId: String?
    public var time: Int64

    public init(id: String, machine: String, sealed: String, outcome: String, allowed: Bool, placeId: String?, time: Int64) {
        self.id = id; self.machine = machine; self.sealed = sealed; self.outcome = outcome
        self.allowed = allowed; self.placeId = placeId; self.time = time
    }
}

/// The app group container shared by the app and the extension.
public struct SharedFiles: Sendable {
    public let root: URL

    public init(root: URL) { self.root = root }

    /// The app group container, or the app's own Application Support when the group is not
    /// available (an unsigned build).
    public static func standard(group: String = "group.com.sealctl.app") -> SharedFiles {
        if let url = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group) {
            return SharedFiles(root: url)
        }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return SharedFiles(root: support.appendingPathComponent("shared", isDirectory: true))
    }

    public var snapshotURL: URL { root.appendingPathComponent("nse-snapshot.bin") }
    public var inboxURL: URL { root.appendingPathComponent("inbox", isDirectory: true) }

    public func writeSnapshot(_ s: ExtensionSnapshot) {
        guard let data = try? JSONEncoder().encode(s) else { return }
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try? data.write(to: snapshotURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    public func readSnapshot() -> ExtensionSnapshot? {
        guard let data = try? Data(contentsOf: snapshotURL) else { return nil }
        return try? JSONDecoder().decode(ExtensionSnapshot.self, from: data)
    }

    public func writeInbox(_ item: InboxItem) {
        try? FileManager.default.createDirectory(at: inboxURL, withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(item) else { return }
        try? data.write(to: inboxURL.appendingPathComponent("\(item.id).json"),
                        options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    /// Reads and deletes the extension's results.
    public func takeInbox() -> [InboxItem] {
        let files = (try? FileManager.default.contentsOfDirectory(at: inboxURL, includingPropertiesForKeys: nil)) ?? []
        var out: [InboxItem] = []
        for f in files where f.pathExtension == "json" {
            if let data = try? Data(contentsOf: f), let item = try? JSONDecoder().decode(InboxItem.self, from: data) {
                out.append(item)
            }
            try? FileManager.default.removeItem(at: f)
        }
        return out
    }

    public func removeAll() {
        try? FileManager.default.removeItem(at: snapshotURL)
        try? FileManager.default.removeItem(at: inboxURL)
    }
}
