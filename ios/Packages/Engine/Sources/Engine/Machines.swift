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
            _ = try? await db.run { try $0.applyStatus(machine: s.machine, status: st, utcOffsetSecs: utcOffset()) }
        }
        await refreshState()
    }

    /// Recently used keys of a machine, for "This machine was lost or stolen".
    public func usage(machine: String?, key: String? = nil, limit: UInt32 = 500) async -> [UsageEntry] {
        (try? await db.run { try $0.usage(machine: machine, key: key, limit: limit) }) ?? []
    }

    /// The days of the Activity log (SPEC.md 11.12), all machines' or one machine's.
    public func activityDays(machine: String?, today: Date = Date(), calendar: Calendar = .current) async -> [ActivityDays.Day] {
        let newest = await usage(machine: machine, limit: 1).first
        let since = ActivityDays.since(newest: newest, today: today, calendar: calendar)
        let entries = (try? await db.run { try $0.usageSince(machine: machine, since: UInt64(since)) }) ?? []
        return ActivityDays.group(entries, today: today, calendar: calendar)
    }

    /// The heatmap's cells: the phone's daily counts over the grid (SPEC.md 11.12).
    public func heatCells(_ grid: HeatGrid) async -> [HeatGrid.Cell] {
        let from = HeatGrid.iso(grid.start, grid.calendar), to = HeatGrid.iso(grid.today, grid.calendar)
        let counts = (try? await db.run { try $0.dailyCounts(fromDay: from, toDay: to, utcOffsetSecs: utcOffset()) }) ?? []
        return grid.cells(counts)
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
        await outsideByFix(fix)
        let sample = LocationSample(lat: fix.lat, lon: fix.lon, accuracy: fix.accuracy, time: UInt64(fix.time))
        let c = try? await db.run { try $0.placeSample(sample: sample, utcOffsetSecs: utcOffset()) }
        await refreshState()
        if let c = c ?? nil {
            placeOffer = c
            await notifier.post(id: "place-\(c.id)", content: Notes.active(Texts.placeLearned, userInfo: ["screen": "place"]))
        }
    }

    /// After a trusted place: location access Always, which region monitoring needs to notice
    /// leaving it (11.9). The system asks once; after that the banner sends the person to the
    /// settings.
    public func askAlways() async {
        if let places, places.hasForeground, !places.hasAlways { await places.requestAlways() }
        refreshLocation()
        await monitorPlaces()
    }

    public func monitorPlaces() async {
        let fences = state.places.filter { !$0.deleted }.map { Fence(id: $0.id, lat: $0.lat, lon: $0.lon, radius: $0.radius) }
        await places?.monitor(fences) { [weak self] ids, entered in
            await self?.onPlaceTransition(ids, entered: entered)
        }
    }

    public func trustPlace(_ c: PlaceCandidate, name: String) async {
        let n = name.trimmingCharacters(in: .whitespaces)
        placeOffer = nil
        // Announced to every paired computer; it skips the wait in two hours (11.9).
        if await !trustPlace(TrustedPlace(id: c.id, name: n.isEmpty ? "Place 1" : String(n.prefix(40)), lat: c.lat,
                                          lon: c.lon, radius: 150, created: UInt64(nowMs()), updated: 0, deleted: false,
                                          manual: false)) {
            show(Texts.relayDown)
        }
        await monitorPlaces()
        await askAlways()
    }

    // MARK: trusting a place (11.9)

    /// Trusts `place` (learned, or "Trust where I am now"). Its comforts start at once; it lifts
    /// the level 3 delay only after two hours, announced to every paired computer and install
    /// through a delayed record on the relay that any of them can cancel ("Run: sealctl cancel"),
    /// and only once the relay confirms nobody did. Returns whether the relay took the
    /// announcement; when not, the place stays unconfirmed and its row offers to announce it again.
    @discardableResult
    public func trustPlace(_ place: TrustedPlace) async -> Bool {
        var p = place
        p.trustId = randomId()
        p.trustFrom = 0
        p.trustedAt = 0
        await apply(.addPlace(place: p), upload: true)
        return await announceTrust(p.id)
    }

    /// Announces trusting the place `placeId` (again, with a new record when the last one ended).
    @discardableResult
    public func announceTrust(_ placeId: String) async -> Bool {
        guard var place = state.places.first(where: { $0.id == placeId && !$0.deleted }) else { return false }
        if place.trustedAt != 0 { return true }
        let id = place.trustId.flatMap { old in local.delayed.contains { $0.id == old } ? nil : old } ?? randomId()
        if id != place.trustId {
            place.trustId = id
            place.trustFrom = 0
            await apply(.addPlace(place: place), upload: true)
        }
        startingDelayed.insert(id)
        writeSnapshot()
        defer {
            startingDelayed.remove(id)
            writeSnapshot()
        }
        do {
            let started = nowMs()
            let d = try await relay.addDelayed(id: id, delay: delaySecs(Self.levelThreeDelaySecs))
            await applyLocal(.putDelayed(action: DelayedAction(
                id: id, what: Texts.place, machine: nil, releaseAt: UInt64(clamping: d.releaseAt),
                expires: UInt64(clamping: d.expires), state: "waiting", cancelledBy: nil,
                started: UInt64(clamping: started), reason: Texts.place, reasonPlace: place.name)))
            if var p = state.places.first(where: { $0.id == placeId && !$0.deleted }) {
                p.trustFrom = UInt64(clamping: d.releaseAt)
                await apply(.addPlace(place: p), upload: true)
            }
            return true
        } catch {
            relayFailed(error)
            return false
        }
    }

    /// The relay says nobody cancelled trusting the place in two hours: it now lifts the delay.
    /// Only while its record is waiting or released here and the place is not confirmed yet, one
    /// at a time: a confirmed one is never asked about again, so a later `404 gone` never
    /// replaces "finished" (11.9, 11.23).
    func confirmPlace(_ id: String) async {
        func due() -> Bool {
            local.delayed.contains { $0.id == id && $0.what == Texts.place && ($0.state == "waiting" || $0.state == "released") }
                && !state.places.contains { $0.trustId == id && !$0.deleted && $0.trustedAt != 0 }
        }
        guard due(), !confirmingPlaces.contains(id) else { return }
        confirmingPlaces.insert(id)
        defer { confirmingPlaces.remove(id) }
        do {
            try await relay.finishDelayed(id)
        } catch let e as RelayError {
            if e.code == "cancelled" {
                if var d = local.delayed.first(where: { $0.id == id }) {
                    d.state = "cancelled"
                    d.cancelledBy = e.body["by"].string
                    await applyLocal(.putDelayed(action: d))
                }
                await untrustCancelled(id)
            } else if e.code == "gone" || ((400..<500).contains(e.status) && ![401, 408, 429].contains(e.status)),
                      var d = local.delayed.first(where: { $0.id == id }) {
                // Gone, or another answer that will not change: not asked again; the row offers Confirm again.
                d.state = "gone"
                await applyLocal(.putDelayed(action: d))
            }
            return
        } catch {
            return
        }
        if var d = local.delayed.first(where: { $0.id == id }) {
            d.state = "finished"
            await applyLocal(.putDelayed(action: d))
        }
        if var p = state.places.first(where: { $0.trustId == id && !$0.deleted }) {
            p.trustedAt = UInt64(clamping: clockNow())
            await apply(.addPlace(place: p), upload: true)
        }
    }

    /// Trusting a place was cancelled (here, from a computer or another install): it is not trusted.
    func untrustCancelled(_ id: String) async {
        guard let p = state.places.first(where: { $0.trustId == id && !$0.deleted && $0.trustedAt == 0 }) else { return }
        await apply(.removePlace(id: p.id), upload: true)
        await monitorPlaces()
    }

    public func suppressPlace(_ c: PlaceCandidate) async {
        await applyLocal(.suppressCandidate(id: c.id))
        placeOffer = nil
    }

    /// Removes a place; trusting it that is still announced is cancelled with it (11.9).
    public func removePlace(_ id: String) async {
        let place = state.places.first { $0.id == id }
        await apply(.removePlace(id: id), upload: true)
        if let p = place, p.trustedAt == 0, let t = p.trustId,
           local.delayed.contains(where: { $0.id == t && ($0.state == "waiting" || $0.state == "released") }) {
            await cancelDelayed(t)
        }
        await monitorPlaces()
    }

    public func renamePlace(_ id: String, _ name: String) async {
        await apply(.renamePlace(id: id, name: String(name.prefix(40))), upload: true)
    }

    /// The phone crossed a place's edge. On exit (also the monitor's record at launch saying
    /// the phone is outside), lock every machine whose allowance came from that place, wherever
    /// its day began. `entered` is nil when the monitor no longer knows (unknown or
    /// unmonitored): the place stops counting as current, but that is not an exit, so nothing
    /// is locked or posted.
    public func onPlaceTransition(_ ids: [String], entered: Bool?) async {
        if entered == true {
            currentPlace = ids.first
            writeSnapshot()
            return
        }
        if let c = currentPlace, ids.contains(c) { currentPlace = nil }
        writeSnapshot()
        guard entered == false else { return }
        await left(ids)
    }

    /// The phone is not inside these places: an exit, or a fix that shows it. An answer decided
    /// at one and still on its way locks its machine once posted, and every machine allowed at
    /// one is locked (11.9).
    func left(_ ids: [String]) async {
        if let c = currentPlace, ids.contains(c) {
            currentPlace = nil
            writeSnapshot()
        }
        for id in ids { placeExits[id, default: 0] += 1 }
        await lockLeft(ids)
    }

    /// Locks every machine allowed at these places and says so, one notification per place.
    func lockLeft(_ ids: [String]) async {
        let locked = await lockGrants(grantsLeft(ids))
        for id in ids {
            guard let place = state.places.first(where: { $0.id == id }) else { continue }
            let names = locked.filter { $0.0.placeId == id }.map { displayName($0.1) }
            if !names.isEmpty {
                await notifier.post(id: "left-\(id)", content: Notes.passive(
                    Texts.leftPlace(place.name, names: names.joined(separator: ", "))))
            }
        }
    }

    /// The allowances to lock now that the phone is not inside these places (the shared core's
    /// rule): each machine's latest session allowed at one, wherever its day began.
    func grantsLeft(_ ids: [String]) async -> [GrantRecord] {
        guard !ids.isEmpty else { return [] }
        return (try? await db.run { try $0.grantsLeft(left: ids, utcOffsetSecs: utcOffset()) }) ?? []
    }

    /// Sends a lock for each allowance and records it once the relay took it; one that did not
    /// go is sent again at the next exit, fix or launch.
    func lockGrants(_ grants: [GrantRecord]) async -> [(GrantRecord, Machine)] {
        var out: [(GrantRecord, Machine)] = []
        for g in grants {
            guard let m = machine(g.machine), await lock(m, reason: "place") else { continue }
            await applyLocal(.grantLocked(grant: g))
            out.append((g, m))
        }
        return out
    }

    var livePlaceIds: [String] { state.places.filter { !$0.deleted }.map(\.id) }

    /// The phone can no longer notice leaving a place (location access Always taken away, or
    /// location turned off): a machine allowed at a trusted place was given its longer
    /// allowance because leaving would lock it, so it is locked now (11.9). Not an exit.
    public func lockUnwatched() async {
        let locked = await lockGrants(grantsLeft(livePlaceIds))
        if !locked.isEmpty {
            await notifier.post(id: "unwatched", content: Notes.passive(
                Texts.placesUnwatched(names: locked.map { displayName($0.1) }.joined(separator: ", "))))
        }
    }

    /// The monitor can report an exit late (or, after a restart, not at all). While a place
    /// counts as current or a machine's allowance came from one, a fresh fix outside that place
    /// counts as leaving it. At most one fix per `minGap` ms.
    public func checkPlaceByFix(minGap: Int64) async {
        if currentPlace == nil, await grantsLeft(livePlaceIds).isEmpty { return }
        let now = nowMs()
        guard now - lastFixCheck >= minGap || now < lastFixCheck else { return }
        lastFixCheck = now
        guard let fix = await places?.sample() else {
            // No fix came: the next check may try again at once.
            if lastFixCheck == now { lastFixCheck = 0 }
            return
        }
        await outsideByFix(fix)
    }

    /// A fix: the trusted places it is clearly outside count as left (11.9).
    func outsideByFix(_ fix: Fix) async {
        let sample = LocationSample(lat: fix.lat, lon: fix.lon, accuracy: fix.accuracy, time: UInt64(max(fix.time, 0)))
        let ids = placesLeftByFix(places: state.places, fix: sample, now: UInt64(nowMs()))
        if !ids.isEmpty { await left(ids) }
    }
}

public struct PairError: Error, Equatable, Sendable {
    public let text: String
    public init(_ text: String) { self.text = text }
}

/// A machine's state (SPEC.md 11.8).
public enum MachineState: Sendable, Equatable {
    case open, waiting, locked, unknown
}

/// A machine's row: its state and the texts of SPEC.md 11.8. `name` is the short name the list
/// shows (SPEC.md 11.17), the same as the Activity rows: the nickname, else the host.
public struct MachineView: Sendable, Identifiable {
    public let machine: Machine
    public let name: String
    public let state: MachineState
    public let row: String
    public let detail: String
    public let leftSecs: Int64?
    /// Spoken in words when Open: "Open, active", "Open, idle 12 minutes, locks at 15:42".
    public var spokenOpen: String? = nil
    public var id: String { machine.key }

    /// The model as the list names it ("Mac mini" for `Mac16,10`), or nil when none was reported.
    public var model: String? { machine.model.map { machineModelName(model: $0) }.flatMap { $0.isEmpty ? nil : $0 } }

    /// "seen 1 h ago"
    public func seen(now: Int64 = nowMs()) -> String { "seen \(Texts.ago(machine.lastSeen.map { Int64($0) }, now: now))" }

    /// The card's muted line (SPEC.md 11.17): "Mac mini · seen 1 h ago".
    public func sub(now: Int64 = nowMs()) -> String { [model, seen(now: now)].compactMap { $0 }.joined(separator: " · ") }

    /// "Not seen for 94 days" for a machine unseen for 90 days, else nil.
    public func unseen(now: Int64 = nowMs()) -> String? {
        machine.flagged ? "Not seen for \((now - Int64(machine.lastSeen ?? 0)) / 86_400_000) days" : nil
    }

    /// The card's one label: "Devs-Mac-mini, Locked · last report 1 h ago, Mac mini, seen 1 h ago".
    public func label(now: Int64 = nowMs()) -> String {
        [name, spoken, model, seen(now: now), unseen(now: now)].compactMap { $0 }.joined(separator: ", ")
    }

    @MainActor
    public static func of(_ m: Machine, _ engine: AppEngine, now: Int64 = nowMs()) -> MachineView {
        let name = machineShortName(machine: m)
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
            let s = machineSession(status: st)
            if let row = openRow(s, now: now) {
                let place = engine.state.places.first { $0.id == st.place }?.name
                let opened = engine.local.days.first { $0.machine == m.key }.map { Int64($0.firstApproval) }
                var detail = ""
                if let opened { detail += "Opened at \(Texts.time(opened))" }
                if let place { detail += " at \(place)" }
                if opened != nil { detail += ". " }
                if isActive(s, now: now), let allow = s.allowanceSecs { detail += "Locks after \(Texts.duration(Int64(allow))) idle. " }
                if let stop = st.stop { detail += "Hard stop at \(Texts.time(Int64(stop)))." }
                let left = (Int64(s.locksAt) - now + 999) / 1000
                return MachineView(machine: m, name: name, state: .open, row: row,
                                   detail: detail.trimmingCharacters(in: .whitespaces), leftSecs: left,
                                   spokenOpen: spokenOpenRow(s, now: now))
            }
            return MachineView(machine: m, name: name, state: .locked, row: "Locked · last report \(Texts.ago(reported, now: now))",
                               detail: "No keys in memory. Volumes unmounted.", leftSecs: nil)
        }
        return MachineView(machine: m, name: name, state: .locked, row: "Locked", detail: "No keys in memory. Volumes unmounted.",
                           leftSecs: nil)
    }

    /// Whether `s` shows the machine as active at `now`: it works, so there is no countdown.
    public static func isActive(_ s: MachineSession, now: Int64) -> Bool {
        s.activeUntil.map { now < Int64($0) } ?? false
    }

    /// The Open row at `now` (SPEC.md 11.8): "Open · active" while the machine works, "Open · idle
    /// 12 min · locks at 15:42" once it is idle, "Open · 2 h 10 min left" from a CLI that sends no
    /// idle time; nil once the time it locks has passed.
    public static func openRow(_ s: MachineSession, now: Int64) -> String? {
        let locksAt = Int64(s.locksAt)
        guard s.open, now < locksAt else { return nil }
        if isActive(s, now: now) { return "Open · active" }
        if let work = s.lastWork {
            return "Open · idle \(Texts.duration(max(now - Int64(work), 0) / 1000)) · locks at \(Texts.time(locksAt))"
        }
        return "Open · \(Texts.duration((locksAt - now + 999) / 1000)) left"
    }

    /// `openRow` in words for VoiceOver: "Open, active", "Open, idle 12 minutes, locks at 15:42",
    /// "Open, 2 hours 10 minutes left".
    public static func spokenOpenRow(_ s: MachineSession, now: Int64) -> String? {
        let locksAt = Int64(s.locksAt)
        guard s.open, now < locksAt else { return nil }
        if isActive(s, now: now) { return "Open, active" }
        if let work = s.lastWork {
            return "Open, idle \(Texts.spokenDuration(max(now - Int64(work), 0) / 1000)), locks at \(Texts.time(locksAt))"
        }
        return "Open, \(Texts.spokenDuration((locksAt - now + 999) / 1000)) left"
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

    /// Spoken as words: "Open, active", "Open, idle 12 minutes, locks at 15:42".
    public var spoken: String {
        switch state {
        case .open: return spokenOpen ?? "Open, \(Texts.spokenDuration(leftSecs ?? 0)) left"
        default: return row
        }
    }
}
