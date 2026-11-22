import Foundation
import EngineKit
import Relay
import SealCore
import UserNotifications
import Vault

extension AppEngine {
    // MARK: the approval path (SPEC.md 9.1)

    public func handle(_ r: RelayRequest, fromPush: Bool) async {
        await approvals.run { [weak self] in await self?.handleOne(r, fromPush: fromPush) }
    }

    private func handleOne(_ r: RelayRequest, fromPush: Bool) async {
        if waiting.contains(where: { $0.relay.id == r.id && !$0.expired }) { return }
        guard (try? await db.run({ try $0.seeRequest(id: r.id, machine: r.machine, expires: UInt64(r.expires)) })) == true else {
            return
        }
        guard let machine = machine(r.machine) else {
            _ = try? await db.run { try $0.closeRequest(id: r.id, outcome: "ignored") }
            return
        }
        guard let keys = await phoneKeys() else { return }
        let req: Request
        do {
            req = try openRequest(keys: keys, relayMachineKey: r.machine, id: r.id, sealed: r.sealed)
        } catch {
            Log.note("request refused by the core: \(type(of: error))")
            _ = try? await db.run { try $0.closeRequest(id: r.id, outcome: "ignored") }
            return
        }
        var plan: RequestPlan?
        if req.kind() == .unseal {
            do {
                let a = assemblers[r.machine] ?? PlanAssembler()
                assemblers[r.machine] = a
                plan = try a.add(request: req)
            } catch {
                _ = await reply(req, r, .refuse(err: .badLabel), outcome: "ignored", allowed: false)
                return
            }
        }
        let verdict = decide(request: req, ctx: await context(r, machine))
        switch verdict.asking {
        case .silent:
            await silent(req, r)
        case .automatic:
            guard let d = verdict.automatic else { return }
            if await reply(req, r, d, outcome: "automatic", allowed: true) {
                let place = currentPlace.flatMap { id in state.places.first { $0.id == id && !$0.deleted }?.name }
                await notifier.post(id: "auto-\(r.id)", content: Notes.passive(Texts.answeredByItself(displayName(machine), place: place)))
            }
        case .planKeys:
            await planKeys(req, r)
        case .refused:
            let err = verdict.refuse ?? .unsupported
            _ = await reply(req, r, .refuse(err: err), outcome: "denied", allowed: false)
            if err == .notNear || err == .noBiometrics {
                let text = err == .notNear ? Texts.notNear(displayName(machine)) : Texts.noBiometrics(biometryName)
                await notifier.post(id: "refused-\(r.id)", content: Notes.active(text))
            }
        case .oneTap, .inApp:
            let w = Waiting(relay: r, request: req, verdict: verdict, machine: machine, seenAt: nowMs(), plan: plan ?? req.plan())
            waiting = waiting.filter { $0.relay.id != r.id } + [w]
            if !foreground || fromPush { await showNotification(w) }
            scheduleExpiry(w)
            await updateBadge()
        }
    }

    func context(_ r: RelayRequest, _ machine: Machine) async -> DecideContext {
        let now = nowMs()
        let plan = local.plans.filter { $0.machine == r.machine && $0.state != "cancelled" }.max { $0.notBefore < $1.notBefore }
        let open: Bool = machine.lastStatus.map { s in
            guard s.session == "open", let left = s.left else { return false }
            return (now - Int64(s.reportedAt)) / 1000 < Int64(left)
        } ?? false
        return DecideContext(
            now: UInt64(now), utcOffsetSecs: utcOffset(), phoneUnlocked: await vault.canReadRoot(),
            near: r.near, onWifi: onWifi, placesOn: places?.hasForeground ?? false, currentPlace: currentPlace,
            currentPlaceSettled: placeSettledNow(),
            day: local.days.first { $0.machine == r.machine },
            answers: state.answers.filter { !$0.deleted }, sessionOpen: open,
            hold: local.holds.first { $0.machine == r.machine },
            biometrics: await vault.biometrics(), plan: plan)
    }

    /// The place the phone is inside also lifts the level 3 delay (a place added by hand: after 24 hours).
    public func placeSettledNow() -> Bool {
        guard let id = currentPlace, let p = state.places.first(where: { $0.id == id && !$0.deleted }) else { return false }
        return SealCore.placeSettled(place: p, now: UInt64(nowMs()))
    }

    /// A level 3 action happens at once here (SPEC.md 9.6).
    public func delayLifted() -> Bool { placeKind() == .trusted && placeSettledNow() }

    public func placeKind() -> SealCore.Place {
        SealCore.placeKind(placesOn: places?.hasForeground ?? false, currentPlace: currentPlace)
    }

    public var currentPlaceName: String? {
        currentPlace.flatMap { id in state.places.first { $0.id == id && !$0.deleted }?.name }
    }

    private func silent(_ req: Request, _ r: RelayRequest) async {
        guard let keys = await phoneKeys() else { return }
        if req.kind() == .unseal {
            guard let sealed = try? sealPlanPartReply(keys: keys, request: req) else { return }
            _ = await post(r, sealed, delay: nil, userTapped: false)
            _ = try? await db.run { try $0.closeRequest(id: r.id, outcome: "answered") }
            return
        }
        let result = try? await db.run { try $0.applyReport(request: req) }
        await refreshState()
        guard let sealed = try? sealReportReply(keys: keys, request: req, ack: result?.ack, messages: []) else { return }
        _ = await post(r, sealed, delay: nil, userTapped: false)
        _ = try? await db.run { try $0.closeRequest(id: r.id, outcome: "answered") }
        if let h = result?.handback { reportArrived(h) }
    }

    func reportArrived(_ report: HandbackReport) {
        let failed = report.items.filter { $0.state == "failed" }.count
        let done = report.items.filter { $0.state == "done" }.count
        let skipped = report.items.filter { $0.state == "skipped" }.count
        Task {
            await notifier.post(id: "report-\(report.id)",
                                content: Notes.active(Texts.handedBack(report.machineName, done: done, failed: failed),
                                                      userInfo: ["screen": "report:\(report.id)"]))
            // Tell every other machine (9.6 Report).
            await sendNotice(what: "unseal_all", state: "done", machine: report.machine, delayId: nil, at: nil,
                             done: done, failed: failed, skipped: skipped)
        }
    }

    private func planKeys(_ req: Request, _ r: RelayRequest) async {
        guard let keys = await phoneKeys(),
              let plan = local.plans.filter({ $0.machine == r.machine }).max(by: { $0.notBefore < $1.notBefore }) else { return }
        let approval = PlanApproval(machine: plan.machine, hash: plan.planHash, notBefore: plan.notBefore,
                                    keys: plan.keys.map { KeyRef(purpose: $0.purpose, id: $0.id) })
        guard let sealed = await withRoot({ try sealPlanKeysReply(root: $0, keys: keys, request: req, approval: approval) }) else { return }
        if await post(r, sealed, delay: nil, userTapped: false) {
            _ = try? await db.run {
                try $0.answered(request: req, outcome: "in_session", allowed: true, remember: false, placeId: nil, utcOffsetSecs: utcOffset())
            }
            await refreshState()
        }
    }

    func scheduleExpiry(_ w: Waiting) {
        expiryTasks[w.relay.id]?.cancel()
        expiryTasks[w.relay.id] = Task { [weak self] in
            let left = w.relay.expires - nowMs()
            if left > 0 { try? await Task.sleep(for: .milliseconds(left)) }
            if Task.isCancelled { return }
            await self?.expire(w.relay.id)
        }
    }

    func expire(_ id: String) async {
        guard let w = waiting.first(where: { $0.relay.id == id && !$0.expired }) else { return }
        markExpired(id)
        await notifier.remove(ids: [id])
        _ = try? await db.run { try $0.closeRequest(id: id, outcome: "expired") }
        _ = try? await db.run {
            try $0.answered(request: w.request, outcome: "expired", allowed: false, remember: false, placeId: nil,
                            utcOffsetSecs: utcOffset())
        }
        await refreshState()
        await updateBadge()
    }

    func markExpired(_ id: String) {
        waiting = waiting.map { var w = $0; if w.relay.id == id { w.expired = true }; return w }
    }

    func drop(_ id: String) {
        waiting.removeAll { $0.relay.id == id }
        expiryTasks[id]?.cancel()
        expiryTasks[id] = nil
    }

    /// Removes an expired card ("Close").
    public func dismiss(_ id: String) { drop(id) }

    func showNotification(_ w: Waiting) async {
        await notifier.post(id: w.relay.id, content: Notes.requestContent(w, machineName: displayName(w.machine), biometry: biometryName))
    }

    /// The decision a button stands for.
    public func decisionFor(_ w: Waiting, _ option: ReplyOption) -> (Decision, String) {
        let place = placeKind()
        switch option {
        case .allowSession: return (w.verdict.agentFirstUse ? .remember(place: place) : .session(place: place), "one_tap")
        case .allow: return (w.verdict.kind == .agent ? .remember(place: place) : .session(place: place), "one_tap")
        case .allowOnce: return (.once(place: place), "once")
        case .deny: return (.deny, "denied")
        case .confirm: return (.once(place: place), "confirmed")
        }
    }

    /// Answers a waiting One tap request (card button or notification action).
    @discardableResult
    public func answer(_ id: String, _ option: ReplyOption) async -> Bool {
        guard let w = waiting.first(where: { $0.relay.id == id && !$0.expired }) else { return false }
        let (decision, outcome) = decisionFor(w, option)
        var remember = false
        if case .remember = decision { remember = true }
        let ok = await reply(w.request, w.relay, decision, outcome: outcome, allowed: option != .deny, remember: remember)
        if ok {
            drop(id)
            await notifier.remove(ids: [id])
            if w.verdict.agentFirstUse { await applyLocal(.agentNoteShown) }
            show(Texts.afterAnswer(option, w))
            await updateBadge()
        }
        return ok
    }

    /// A notification action: fetch the request again if this process did not see it.
    public func answerFromNotification(_ id: String, action: String) async {
        guard let option = Texts.option(actionId: action) else { return }
        if !waiting.contains(where: { $0.relay.id == id }) { await catchUp() }
        if option != .deny, !(await vault.canReadRoot()) {
            let name = waiting.first { $0.relay.id == id }.map { displayName($0.machine) } ?? ""
            await notifier.post(id: "unlock-\(id)", content: Notes.active(Texts.unlockToAnswer(name)))
            return
        }
        await answer(id, option)
    }

    /// Seals and posts one reply, then records it. False when it could not be sealed or the
    /// machine stopped waiting.
    func reply(_ req: Request, _ r: RelayRequest, _ decision: Decision, outcome: String, allowed: Bool,
               remember: Bool = false, delay: Int? = nil) async -> Bool {
        guard let keys = await phoneKeys() else { return false }
        let needsRoot = allowed && !req.items().isEmpty
        let sealed: String
        if needsRoot {
            guard let root = await vault.readRoot() else {
                show(Texts.unlockToAnswerShort)
                return false
            }
            guard let s = try? sealReply(root: root, keys: keys, request: req, decision: decision) else { return false }
            sealed = s
        } else {
            guard let s = try? sealReply(root: nil, keys: keys, request: req, decision: decision) else { return false }
            sealed = s
        }
        let posted = await post(r, sealed, delay: delay, userTapped: true)
        if posted {
            answeredIds.insert(r.id)
            let place = currentPlace
            let result = try? await db.run {
                try $0.answered(request: req, outcome: outcome, allowed: allowed, remember: remember, placeId: place,
                                utcOffsetSecs: utcOffset())
            }
            _ = try? await db.run { try $0.closeRequest(id: r.id, outcome: "answered") }
            if result?.firstOfDay == true { Task { await self.firstApprovalOfDay() } }
            await refreshState()
            scheduleUpload(after: 10)
        }
        return posted
    }

    /// Posts a reply with the retries of 8.5: 1, 2, 4 s, then every 10 s until `expires`.
    func post(_ r: RelayRequest, _ sealed: String, delay: Int?, userTapped: Bool) async -> Bool {
        let backoff: [Double] = [1, 2, 4]
        var attempt = 0
        // `try? Task.sleep` returns at once in a cancelled task: stop then, or this spins until `expires`.
        while nowMs() < r.expires && !Task.isCancelled {
            do {
                try await relay.reply(id: r.id, sealed: sealed, delay: delay, userTapped: userTapped)
                relayOk()
                return true
            } catch let e as RelayError {
                if e.code == "gone" {
                    _ = try? await db.run { try $0.closeRequest(id: r.id, outcome: "expired") }
                    markExpired(r.id)
                    return false
                }
                relayFailed(e)
                if case .rateLimited = e { return false }
                if (400..<500).contains(e.status) { return false }
            } catch {
                relayFailed(error)
            }
            try? await Task.sleep(for: .seconds(attempt < backoff.count ? backoff[attempt] : 10))
            attempt += 1
        }
        return false
    }

    // MARK: levels 2 and 3 (9.6)

    /// A wrong number: refuse with `no_match` and hold the machine for an hour.
    public func wrongNumber(_ w: Waiting) async {
        _ = await reply(w.request, w.relay, .refuse(err: .noMatch), outcome: "denied", allowed: false)
        await applyLocal(.setHold(hold: Hold(machine: w.machine.key, until: UInt64(nowMs() + 3_600_000))))
        drop(w.relay.id)
    }

    public func releaseHold(_ machine: String) async { await applyLocal(.clearHold(machine: machine)) }

    /// Denies a sensitive request (Deny, "I don't see a number").
    public func deny(_ w: Waiting) async {
        _ = await reply(w.request, w.relay, .deny, outcome: "denied", allowed: false)
        drop(w.relay.id)
        await notifier.remove(ids: [w.relay.id])
    }

    /// Refuses a sensitive request for a reason (no biometrics, unsupported).
    public func refuse(_ w: Waiting, _ err: RefuseReason) async {
        _ = await reply(w.request, w.relay, .refuse(err: err), outcome: "denied", allowed: false)
        drop(w.relay.id)
        await notifier.remove(ids: [w.relay.id])
    }

    /// The level 3 delay in seconds (shortened only in debug builds that ask for it).
    public func delaySecs(_ verdictDelay: Int) -> Int {
        verdictDelay > 0 && config.testDelaySecs > 0 ? config.testDelaySecs : verdictDelay
    }

    /// After biometrics: answers a level 2 or 3 request. `unseal` signs the plan, with the
    /// not-before time two hours on away from a trusted place.
    public func confirmSensitive(_ w: Waiting) async -> Bool {
        let place = placeKind()
        switch w.verdict.kind {
        case .unseal:
            let delay = delaySecs(Int(w.verdict.delaySecs))
            let notBefore = nowMs() + Int64(delay) * 1000
            let ok = await reply(w.request, w.relay, .plan(place: place, notBefore: UInt64(notBefore)), outcome: "confirmed",
                                 allowed: true, delay: delay > 0 ? delay : nil)
            guard ok else { return false }
            let plan = w.plan ?? w.request.plan()
            var keys: [KeyRefRecord] = []
            for i in plan?.items ?? [] {
                if let p = i.purpose, let id = i.id, !keys.contains(where: { $0.purpose == p && $0.id == id }) {
                    keys.append(KeyRefRecord(purpose: p, id: id))
                }
            }
            await applyLocal(.putPlan(plan: PlanApprovalRecord(
                machine: w.machine.key, requestId: w.relay.id, planHash: plan?.hash ?? "",
                items: plan?.items.map { PlanItemRecord(kind: $0.kind, name: $0.name, purpose: $0.purpose, id: $0.id) } ?? [],
                keys: keys, notBefore: UInt64(notBefore), state: delay > 0 ? "delayed" : "approved",
                delayId: delay > 0 ? w.relay.id : nil, all: plan?.all ?? false)))
            if delay > 0 {
                await applyLocal(.putDelayed(action: DelayedAction(
                    id: w.relay.id, what: "unseal_all", machine: w.machine.key, releaseAt: UInt64(notBefore),
                    expires: UInt64(notBefore + 900_000), state: "waiting", cancelledBy: nil)))
                Task { await self.sendNotice(what: "unseal_all", state: "pending", machine: w.machine.key, delayId: w.relay.id, at: notBefore) }
            }
            drop(w.relay.id)
            await notifier.remove(ids: [w.relay.id])
            return true
        case .keys:
            let ok = await reply(w.request, w.relay, .once(place: place), outcome: "confirmed", allowed: true)
            if ok {
                drop(w.relay.id)
                await notifier.remove(ids: [w.relay.id])
            }
            return ok
        default:
            // rewrap and old_words need a change of words in progress (not built yet).
            await refuse(w, .unsupported)
            return false
        }
    }

    // MARK: delayed approvals (11.23)

    public func refreshDelayed() async {
        guard await phoneKeys() != nil, let list = try? await relay.listDelayed() else { return }
        for d in list {
            if let mine = local.delayed.first(where: { $0.id == d.id }) {
                if mine.state != d.state && mine.state != "cancelled" {
                    var m = mine
                    m.state = d.state
                    if d.state == "cancelled" { m.cancelledBy = await relay.cancelledBy(d.id) }
                    await applyLocal(.putDelayed(action: m))
                }
            } else {
                await applyLocal(.putDelayed(action: DelayedAction(
                    id: d.id, what: d.machine != nil ? "unseal_all" : "unknown", machine: d.machine,
                    releaseAt: UInt64(d.releaseAt), expires: UInt64(d.expires), state: d.state, cancelledBy: nil)))
            }
        }
        // Records the relay no longer has: fetched by the machine, finished or expired.
        let ids = Set(list.map(\.id))
        for d in local.delayed where !ids.contains(d.id) && d.state == "waiting" && nowMs() > Int64(d.releaseAt) {
            var m = d
            // A machine's record leaves when the machine fetches it; a phone-only one leaves
            // only when this phone finishes it or it expires, so a missing one is gone.
            m.state = d.machine == nil ? "gone" : "released"
            await applyLocal(.putDelayed(action: m))
        }
        delayedTick = nowMs()
    }

    /// Cancel needs no biometrics: stopping is always allowed.
    @discardableResult
    public func cancelDelayed(_ id: String) async -> Bool {
        let d = local.delayed.first { $0.id == id }
        do {
            try await relay.cancelDelayed(id)
        } catch {
            relayFailed(error)
            return false
        }
        if var m = d {
            m.state = "cancelled"
            m.cancelledBy = "phone"
            await applyLocal(.putDelayed(action: m))
        }
        if var p = local.plans.first(where: { $0.delayId == id }) {
            p.state = "cancelled"
            await applyLocal(.putPlan(plan: p))
        }
        await notifier.remove(ids: ["ready-\(id)"])
        Task {
            await self.sendNotice(what: d?.what ?? "unseal_all", state: "cancelled", machine: d?.machine, delayId: id,
                                  at: d.map { Int64($0.releaseAt) })
        }
        delayedTick = nowMs()
        return true
    }

    /// Starts a level 3 action on the phone: nil (go ahead now) at a trusted place, else the
    /// delayed record the relay keeps for the hour.
    public func startPhoneAction(_ what: String) async throws -> DelayedAction? {
        if delayLifted() { return nil }
        let delay = delaySecs(7200)
        let id = randomId()
        let d = try await relay.addDelayed(id: id, delay: delay)
        let action = DelayedAction(id: id, what: what, machine: nil, releaseAt: UInt64(d.releaseAt), expires: UInt64(d.expires),
                                   state: "waiting", cancelledBy: nil)
        await applyLocal(.putDelayed(action: action))
        await notifier.post(id: "ready-\(id)", content: Notes.active(Texts.ready(what), level: .timeSensitive,
                                                                     userInfo: ["screen": "delayed:\(id)"]),
                            at: Date(timeIntervalSince1970: Double(d.releaseAt) / 1000))
        Task { await self.sendNotice(what: what, state: "pending", machine: nil, delayId: id, at: d.releaseAt) }
        return action
    }

    /// After the hour and biometrics again: the relay must answer `finish` with 200.
    /// Returns nil on success, else `too_early`, `gone`, `relay` or `cancelled:<by>`.
    public func finishPhoneAction(_ id: String) async -> String? {
        do {
            try await relay.finishDelayed(id)
            if var d = local.delayed.first(where: { $0.id == id }) {
                d.state = "finished"
                await applyLocal(.putDelayed(action: d))
            }
            return nil
        } catch let e as RelayError {
            switch e.code {
            case "cancelled":
                let by = e.body["by"].string
                if var d = local.delayed.first(where: { $0.id == id }) {
                    d.state = "cancelled"
                    d.cancelledBy = by
                    await applyLocal(.putDelayed(action: d))
                }
                return "cancelled:" + (by ?? "")
            case "too_early": return "too_early"
            case "gone":
                // Terminal: the relay no longer has it (it expired). Record that, so the screen
                // offers a new start instead of a Finish that can only get `gone` again.
                if var d = local.delayed.first(where: { $0.id == id }) {
                    d.state = "gone"
                    await applyLocal(.putDelayed(action: d))
                }
                return "gone"
            default: return "relay"
            }
        } catch {
            return "relay"
        }
    }

    /// A sealed `notice` to every paired machine (9.6).
    public func sendNotice(what: String, state st: String, machine: String?, delayId: String?, at: Int64?,
                           done: Int = 0, failed: Int = 0, skipped: Int = 0) async {
        guard let keys = await phoneKeys() else { return }
        let report = st == "done" ? NoticeReport(done: UInt64(done), failed: UInt64(failed), skipped: UInt64(skipped), to: []) : nil
        let name = machine.flatMap { self.machine($0)?.name }
        for m in liveMachines where !m.boxKey.isEmpty {
            let seq = await nextSeq(m.key)
            let msg = MachineMessage(version: 1, time: UInt64(nowMs()), seq: seq,
                                     kind: .notice(notice: Notice(what: what, state: st, machine: name, delay: delayId,
                                                                  at: at.map { UInt64($0) }, report: report)))
            if let sealed = try? sealMachineMessage(keys: keys, machineKey: m.key, machineBoxKey: m.boxKey, message: msg) {
                _ = try? await relay.postMessage(machine: m.key, sealed: sealed)
            }
        }
    }

    func nextSeq(_ machine: String) async -> UInt64 {
        (try? await db.run { try $0.nextMessageSeq(machine: machine) }) ?? UInt64(nowMs())
    }
}
