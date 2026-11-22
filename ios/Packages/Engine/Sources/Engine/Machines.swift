import Foundation
import EngineKit
import Places
import Relay
import SealCore
import UserNotifications

extension AppEngine {
    // MARK: machines (11.17)

    /// Sends a lock to a machine; the relay holds it up to 24 hours.
    @discardableResult
    public func lock(_ machine: Machine, reason: String = "phone") async -> Bool {
        guard let keys = await phoneKeys(), !machine.boxKey.isEmpty else { return false }
        let msg = MachineMessage(version: 1, time: UInt64(nowMs()), seq: await nextSeq(machine.key), kind: .lock(reason: reason))
        do {
            let sealed = try sealMachineMessage(keys: keys, machineKey: machine.key, machineBoxKey: machine.boxKey, message: msg)
            try await relay.postMessage(machine: machine.key, sealed: sealed)
            return true
        } catch {
            relayFailed(error)
            return false
        }
    }

    public func lockAll() async -> Int {
        var n = 0
        for m in liveMachines where MachineView.of(m, self).state == .open {
            if await lock(m) { n += 1 }
        }
        return n
    }

    @discardableResult
    public func unpair(_ machine: Machine) async -> Bool {
        await lock(machine)
        do {
            try await relay.removeMachine(machine.key)
            await apply(.unpairMachine(key: machine.key), upload: true)
            return true
        } catch {
            relayFailed(error)
            return false
        }
    }

    public func setNickname(_ key: String, _ nickname: String?) async {
        let n = nickname?.trimmingCharacters(in: .whitespaces)
        await apply(.setNickname(key: key, nickname: n?.isEmpty == false ? String(n!.prefix(40)) : nil))
    }

    /// A relay time below zero reads as zero.
    nonisolated static func seen(_ m: RelayMachine) -> MachineSeen {
        MachineSeen(key: m.machine, lastSeen: m.lastSeen.map { UInt64(clamping: $0) })
    }

    public func refreshMachines() async {
        guard await phoneKeys() != nil, let list = try? await relay.machines() else { return }
        await apply(.machinesListed(seen: list.map(Self.seen)))
        let keys = Set(list.map(\.machine))
        relayMachines = keys
        // A machine that unpaired itself (`sealctl unseal --all`, `sealctl unpair`) leaves the
        // list; while leaving, the rows stay to show "Handed back".
        if local.leaveStep == 0 {
            for m in liveMachines where !keys.contains(m.key) {
                await apply(.unpairMachine(key: m.key))
            }
        }
    }

    public func refreshStatus() async {
        guard let keys = await phoneKeys(), let list = try? await relay.status() else { return }
        for s in list where machine(s.machine) != nil {
            guard let st = try? openMachineStatus(keys: keys, machineKey: s.machine, sealed: s.sealed) else { continue }
            _ = try? await db.run { try $0.applyStatus(machine: s.machine, status: st) }
        }
        await refreshState()
    }

    /// Recently used keys of a machine, for "This machine was lost or stolen".
    public func usage(machine: String?, key: String? = nil, limit: UInt32 = 500) async -> [UsageEntry] {
        (try? await db.run { try $0.usage(machine: machine, key: key, limit: limit) }) ?? []
    }

    // MARK: pairing (11.5)

    /// Parses a scanned or typed code; the offer or the error text of 11.20.
    public func parseOffer(_ text: String) -> Result<PairingOffer, PairError> {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            let offer = try PairingOffer.parse(text: Self.normalizeLink(t))
            var theirs = offer.relayOrigin()
            while theirs.hasSuffix("/") { theirs.removeLast() }
            if theirs != relay.baseURL {
                return .failure(PairError(Texts.otherRelay(theirs, ours: relay.host)))
            }
            return .success(offer)
        } catch CoreError.Expired {
            return .failure(PairError(Texts.codeExpired))
        } catch CoreError.NewerVersion {
            return .failure(PairError(Texts.newerVersion))
        } catch {
            return .failure(PairError(Texts.notACode))
        }
    }

    /// The app also answers `sealctl://p#<payload>` (universal links need a signed build);
    /// the core reads the `https://sealctl.com/p#` link and the bare payload.
    public static func normalizeLink(_ t: String) -> String {
        if t.hasPrefix("sealctl://"), let hash = t.firstIndex(of: "#") {
            return "https://sealctl.com/p" + t[hash...]
        }
        return t
    }

    /// Registers the machine with the relay after biometrics.
    public func pair(_ offer: PairingOffer, replaces: String?) async -> Result<Machine, PairError> {
        guard let keys = await phoneKeys() else { return .failure(PairError(Texts.unlockToAnswerShort)) }
        let proof = pairingProof(keys: keys, offer: offer)
        do {
            try await relay.addMachine(machine: offer.machineKey(), name: offer.name(), os: offer.os(), model: offer.model(),
                                       proof: proof)
            let now = UInt64(nowMs())
            let m = Machine(key: offer.machineKey(), boxKey: offer.machineBoxKey(), name: offer.name(), os: offer.os(),
                            model: offer.model(), hint: offer.hint(), pairedAt: now, nickname: nil, lastSeen: now,
                            lastStatus: nil, tagShown: false, flagged: false, relay: offer.relayOrigin(), updated: 0, deleted: false)
            await apply(.pairMachine(machine: m, replaces: replaces), upload: true)
            if let replaces { try? await relay.removeMachine(replaces) }
            return .success(m)
        } catch let e as RelayError {
            if e.code == "too_many_machines" { return .failure(PairError(Texts.tooMany)) }
            if e.status == 402 { return .failure(PairError(Texts.licenceRequired)) }
            if e.status == 0 { return .failure(PairError(Texts.relayDown)) }
            return .failure(PairError(Texts.relayError(e.code)))
        } catch {
            return .failure(PairError(Texts.relayDown))
        }
    }

    // MARK: places (11.9)

    func firstApprovalOfDay() async {
        guard let fix = await places?.sample() else { return }
        let sample = LocationSample(lat: fix.lat, lon: fix.lon, accuracy: fix.accuracy, time: UInt64(fix.time))
        let c = try? await db.run { try $0.placeSample(sample: sample, utcOffsetSecs: utcOffset()) }
        await refreshState()
        if let c = c ?? nil {
            placeOffer = c
            await notifier.post(id: "place-\(c.id)", content: Notes.active(Texts.placeLearned, userInfo: ["screen": "place"]))
        }
    }

    public func monitorPlaces() async {
        let fences = state.places.filter { !$0.deleted }.map { Fence(id: $0.id, lat: $0.lat, lon: $0.lon, radius: $0.radius) }
        await places?.monitor(fences) { [weak self] ids, entered in
            await self?.onPlaceTransition(ids, entered: entered)
        }
    }

    public func trustPlace(_ c: PlaceCandidate, name: String) async {
        let n = name.trimmingCharacters(in: .whitespaces)
        await apply(.addPlace(place: TrustedPlace(id: c.id, name: n.isEmpty ? "Place 1" : String(n.prefix(40)), lat: c.lat,
                                                  lon: c.lon, radius: 150, created: UInt64(nowMs()), updated: 0, deleted: false, manual: false)),
                    upload: true)
        placeOffer = nil
        await monitorPlaces()
        if let places, !places.hasAlways { await places.requestAlways() }
    }

    public func suppressPlace(_ c: PlaceCandidate) async {
        await applyLocal(.suppressCandidate(id: c.id))
        placeOffer = nil
    }

    public func removePlace(_ id: String) async {
        await apply(.removePlace(id: id), upload: true)
        await monitorPlaces()
    }

    public func renamePlace(_ id: String, _ name: String) async {
        await apply(.renamePlace(id: id, name: String(name.prefix(40))), upload: true)
    }

    /// The phone crossed a place's edge; on exit, lock every machine whose day began there.
    /// `entered` is nil when the monitor no longer knows (unknown or unmonitored): the place
    /// stops counting as current, but that is not an exit, so nothing is locked or posted.
    public func onPlaceTransition(_ ids: [String], entered: Bool?) async {
        if entered == true {
            currentPlace = ids.first
            writeSnapshot()
            return
        }
        if let c = currentPlace, ids.contains(c) { currentPlace = nil }
        writeSnapshot()
        guard entered == false else { return }
        for id in ids {
            guard let place = state.places.first(where: { $0.id == id }) else { continue }
            var locked: [Machine] = []
            for d in local.days where d.placeId == id {
                if let m = machine(d.machine), await lock(m, reason: "place") { locked.append(m) }
            }
            if !locked.isEmpty {
                await notifier.post(id: "left-\(id)", content: Notes.passive(
                    Texts.leftPlace(place.name, names: locked.map(displayName).joined(separator: ", "))))
            }
        }
    }
}

public struct PairError: Error, Equatable, Sendable {
    public let text: String
    public init(_ text: String) { self.text = text }
}

/// A machine's row: its state and the texts of SPEC.md 11.8.
public enum MachineState: Sendable, Equatable {
    case open, waiting, locked, unknown
}

public struct MachineView: Sendable, Identifiable {
    public let machine: Machine
    public let name: String
    public let state: MachineState
    public let row: String
    public let detail: String
    public let leftSecs: Int64?
    public var id: String { machine.key }

    @MainActor
    public static func of(_ m: Machine, _ engine: AppEngine, now: Int64 = nowMs()) -> MachineView {
        let name = engine.displayName(m)
        if let w = engine.waiting.first(where: { $0.machine.key == m.key && !$0.expired }) {
            let secs = (now - min(w.relay.created, now)) / 1000
            return MachineView(machine: m, name: name, state: .waiting, row: String(format: "Waiting · %d:%02d", secs / 60, secs % 60),
                               detail: "A request is on this phone.", leftSecs: nil)
        }
        guard let st = m.lastStatus else {
            return MachineView(machine: m, name: name, state: .unknown, row: "Seen \(Texts.ago(m.lastSeen.map { Int64($0) }, now: now))",
                               detail: "This machine hasn't reported its state yet.", leftSecs: nil)
        }
        let reported = Int64(st.reportedAt)
        if st.session == "open" {
            let left = Int64(st.left ?? 0) - (now - reported) / 1000
            if left > 0 {
                let place = engine.state.places.first { $0.id == st.place }?.name
                let opened = engine.local.days.first { $0.machine == m.key }.map { Int64($0.firstApproval) }
                var detail = ""
                if let opened { detail += "Opened at \(Texts.time(opened))" }
                if let place { detail += " at \(place)" }
                if opened != nil { detail += ". " }
                if let stop = st.stop { detail += "Hard stop at \(Texts.time(Int64(stop)))." }
                return MachineView(machine: m, name: name, state: .open, row: "Open · \(Texts.duration(left)) left",
                                   detail: detail.trimmingCharacters(in: .whitespaces), leftSecs: left)
            }
            return MachineView(machine: m, name: name, state: .locked, row: "Locked (last report \(Texts.ago(reported, now: now)))",
                               detail: "No keys in memory. Volumes unmounted.", leftSecs: nil)
        }
        return MachineView(machine: m, name: name, state: .locked, row: "Locked", detail: "No keys in memory. Volumes unmounted.",
                           leftSecs: nil)
    }

    /// Waiting, then Open, then Locked, then by last seen (11.17).
    public static func sorted(_ list: [MachineView]) -> [MachineView] {
        func rank(_ s: MachineState) -> Int {
            switch s { case .waiting: 0; case .open: 1; case .locked: 2; case .unknown: 3 }
        }
        return list.sorted {
            if rank($0.state) != rank($1.state) { return rank($0.state) < rank($1.state) }
            return ($0.machine.lastSeen ?? 0) > ($1.machine.lastSeen ?? 0)
        }
    }

    /// Spoken as words: "Open, 2 hours 10 minutes left."
    public var spoken: String {
        switch state {
        case .open: return "Open, \(Texts.spokenDuration(leftSecs ?? 0)) left"
        default: return row
        }
    }
}
