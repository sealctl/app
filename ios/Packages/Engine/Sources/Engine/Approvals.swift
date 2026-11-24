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
        guard (try? await db.run({ try $0.seeRequest(id: r.id, machine: r.machine, expires: UInt64(clamping: r.expires)) })) == true else {
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
        if req.level() >= 3 { await freshClockAtHandAddedPlace() }
        let mark = placeMark()
        var ctx = await context(r, machine)
        var verdict = decide(request: req, ctx: ctx)
        if verdict.asking == .planKeys, ctx.plan?.delayId != nil {
            // A cancel made on a computer reaches this phone only by the socket, a push or a refresh:
            // ask the relay before a delayed plan hands out keys. Without an answer, ask the person.
            ctx.plan = await refreshDelayed() ? livePlan(r.machine) : nil
            verdict = decide(request: req, ctx: ctx)
        }
        switch verdict.asking {
        case .silent:
            await silent(req, r)
        case .automatic:
            guard let d = verdict.automatic else { return }
            switch await send(req, r, d, outcome: "automatic", allowed: true, decidedAt: mark) {
            case .posted:
                let place = currentPlace.flatMap { id in state.places.first { $0.id == id && !$0.deleted }?.name }
                await notifier.post(id: "auto-\(r.id)", content: Notes.passive(Texts.answeredByItself(displayName(machine), place: place)))
            case .failed, .locked:
                // Fail closed: the person answers instead of the request waiting unseen (9.1).
                guard let again = try? openRequest(keys: keys, relayMachineKey: r.machine, id: r.id, sealed: r.sealed) else { return }
                var asked = verdict
                asked.asking = .oneTap
                asked.automatic = nil
                await ask(again, r, asked, machine, plan: plan, fromPush: fromPush)
            case .gone:
                break
            }
        case .planKeys:
            guard let plan = ctx.plan else { return }
            await planKeys(req, r, plan)
        case .refused:
            let err = verdict.refuse ?? .unsupported
            _ = await reply(req, r, .refuse(err: err), outcome: "denied", allowed: false)
            if err == .notNear || err == .noBiometrics {
                let text = err == .notNear ? Texts.notNear(displayName(machine)) : Texts.noBiometrics(biometryName)
                await notifier.post(id: "refused-\(r.id)", content: Notes.active(text))
            }
        case .oneTap, .inApp:
            await ask(req, r, verdict, machine, plan: plan, fromPush: fromPush)
        }
    }

    /// Puts a request on the card, with a notification when the app is not on screen.
    private func ask(_ req: Request, _ r: RelayRequest, _ verdict: Verdict, _ machine: Machine, plan: RequestPlan?,
                     fromPush: Bool) async {
        let w = Waiting(relay: r, request: req, verdict: verdict, machine: machine, seenAt: now(), plan: plan ?? req.plan())
        waiting = waiting.filter { $0.relay.id != r.id } + [w]
        if !foreground || fromPush { await showNotification(w) }
        scheduleExpiry(w)
        await updateBadge()
    }

    func context(_ r: RelayRequest, _ machine: Machine) async -> DecideContext {
        let now = clockNow()
        let plan = livePlan(r.machine)
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

    /// The newest plan of a machine that can still hand out keys: not cancelled, and not
    /// waiting on a delayed record that was cancelled.
    func livePlan(_ machine: String) -> PlanApprovalRecord? {
        let cancelled = Set(local.delayed.filter { $0.state == "cancelled" }.map(\.id))
        return local.plans
            .filter { $0.machine == machine && $0.state != "cancelled" && !($0.delayId.map(cancelled.contains) ?? false) }
            .max { $0.notBefore < $1.notBefore }
    }

    /// The clock every security window is counted on (SPEC.md 8.1): holds, plans, the level 3
    /// delay and places. The relay's time while fresh, else the later of the system clock and
    /// the last-known relay time.
    public func clockNow() -> Int64 { Int64(clamping: db.clockNow().now) }

    /// The place the phone is inside also lifts the level 3 delay: a place added by hand after
    /// 24 hours on the corrected clock, and never while that clock is stale (8.1, 9.6).
    public func placeSettledNow() -> Bool {
        guard let id = currentPlace, let p = state.places.first(where: { $0.id == id && !$0.deleted }) else { return false }
        return placeSettledAt(place: p, now: db.clockNow())
    }

    /// Before a level 3 decision at a place added by hand: a stale clock would not let the place
    /// lift the delay, so the relay's time is asked first.
    func freshClockAtHandAddedPlace() async {
        guard let id = currentPlace, let p = state.places.first(where: { $0.id == id && !$0.deleted }), p.manual,
              !db.clockNow().fresh else { return }
        if await relay.relayTime() != nil { writeSnapshot() }
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
        let result = try? await db.run { try $0.applyReport(request: req, utcOffsetSecs: utcOffset()) }
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

    /// Answers a later part of `plan`, the plan `decide` matched the request to.
    private func planKeys(_ req: Request, _ r: RelayRequest, _ plan: PlanApprovalRecord) async {
        guard let keys = await phoneKeys() else { return }
        let approval = PlanApproval(machine: plan.machine, hash: plan.planHash, notBefore: plan.notBefore,
                                    keys: plan.keys.map { KeyRef(purpose: $0.purpose, id: $0.id) })
        guard let sealed = await withRoot({ try sealPlanKeysReply(root: $0, keys: keys, request: req, approval: approval) }) else { return }
        if await post(r, sealed, delay: nil, userTapped: false) == .posted {
            _ = try? await db.run {
                try $0.answered(request: req, outcome: "in_session", allowed: true, remember: false, placeId: nil, utcOffsetSecs: utcOffset())
            }
            await refreshState()
        }
    }

    func scheduleExpiry(_ w: Waiting) {
        expiryTasks[w.relay.id]?.cancel()
        expiryTasks[w.relay.id] = Task { [weak self] in
            let left = w.deadline - (self?.now() ?? nowMs())
            if left > 0 { try? await Task.sleep(for: .milliseconds(left)) }
            if Task.isCancelled { return }
            await self?.expire(w.relay.id)
        }
    }

    /// The card's time is up. While an answer is on its way the answer decides: the relay
    /// takes it, or the answer closes the card when it fails after the deadline.
    func expire(_ id: String) async {
        guard !answering.contains(id), let w = waiting.first(where: { $0.relay.id == id && !$0.expired }) else { return }
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

    /// Answers a waiting One tap request (card button or notification action) with one of
    /// the options it offers. Level 2 and 3 requests are answered only in the app (9.6).
    /// A tap after the card's time, or an answer already on its way (from a notification action
    /// and the card at once), sends nothing. A reply the relay did not take keeps the card and
    /// says so (SPEC.md 8.5, 11.7).
    @discardableResult
    public func answer(_ id: String, _ option: ReplyOption) async -> Bool {
        await answerOutcome(id, option) == .posted
    }

    func answerOutcome(_ id: String, _ option: ReplyOption) async -> Sent? {
        guard !answering.contains(id), let w = waiting.first(where: { $0.relay.id == id && !$0.expired }),
              w.verdict.asking == .oneTap, w.verdict.options.contains(option) else { return nil }
        if now() >= w.deadline {
            // The timer did not run (a late timer, a resumed process): the card stops waiting.
            await expire(id)
            return .gone
        }
        let mark = placeMark()
        let (decision, outcome) = decisionFor(w, option)
        var remember = false
        if case .remember = decision { remember = true }
        guard let sent = await answerCard(w, {
            await send(w.request, w.relay, decision, outcome: outcome, allowed: option != .deny, remember: remember,
                       decidedAt: mark)
        }) else { return nil }
        switch sent {
        case .posted:
            drop(id)
            await notifier.remove(ids: [id])
            if w.verdict.agentFirstUse { await applyLocal(.agentNoteShown) }
            show(Texts.afterAnswer(option, w))
            await updateBadge()
        case .failed:
            if waiting.contains(where: { $0.relay.id == id && !$0.expired }) { show(Texts.answerNotSent) }
        case .gone, .locked:
            // `404 gone` says "stopped waiting"; reply() said "Unlock your phone to answer."
            break
        }
        return sent
    }

    /// Answers the card `w` with `body`: one answer per request at a time, and the card's timer
    /// leaves the card to an answer on its way (SPEC.md 8.5). A reply that did not go closes the
    /// card when its time is up, or sets its timer again (it may have fired meanwhile). Nil when
    /// an answer to the request is already on its way.
    func answerCard(_ w: Waiting, _ body: () async -> Sent) async -> Sent? {
        let id = w.relay.id
        guard answering.insert(id).inserted else { return nil }
        let sent = await body()
        answering.remove(id)
        guard sent != .posted, waiting.contains(where: { $0.relay.id == id && !$0.expired }) else { return sent }
        if sent == .gone || now() >= w.deadline {
            await expire(id)
        } else {
            scheduleExpiry(w)
        }
        return sent
    }

    /// The card's current request: a reply that did not go opened it again (`reopen`).
    func current(_ w: Waiting) -> Waiting { waiting.first { $0.relay.id == w.relay.id } ?? w }

    /// A notification action: fetch the request again if this process did not see it. When the
    /// answer can't be sent, the request's notification comes back saying so (SPEC.md 10.1).
    public func answerFromNotification(_ id: String, action: String) async {
        guard let option = Texts.option(actionId: action) else { return }
        if !waiting.contains(where: { $0.relay.id == id }) {
            if !(await catchUp()) {
                await notifier.post(id: id, content: Notes.active(Texts.requestTitle, body: Texts.answerNotSent,
                                                                  userInfo: ["id": id]))
                return
            }
        }
        if option != .deny, !(await vault.canReadRoot()) {
            let name = waiting.first { $0.relay.id == id }.map { displayName($0.machine) } ?? ""
            await notifier.post(id: "unlock-\(id)", content: Notes.active(Texts.unlockToAnswer(name)))
            return
        }
        if await answerOutcome(id, option) == .failed, let w = waiting.first(where: { $0.relay.id == id && !$0.expired }) {
            let content = Notes.requestContent(w, machineName: displayName(w.machine), biometry: biometryName)
            content.body = Texts.answerNotSent
            await notifier.post(id: id, content: content)
        }
    }

    /// Where the phone was when a decision was made, and how many place exits it had seen.
    struct PlaceMark {
        let place: String?
        let exits: Int
    }

    func placeMark() -> PlaceMark { PlaceMark(place: currentPlace, exits: placeExits) }

    /// What became of one reply.
    enum Sent: Equatable {
        /// The relay took it.
        case posted
        /// The machine stopped waiting (`404 gone`, or the request's time ran out).
        case gone
        /// The root could not be read: "Unlock your phone to answer."
        case locked
        /// Not sealed, or the relay did not take it; the request can be answered again.
        case failed
    }

    /// Seals and posts one reply, then records it. False when it could not be sealed or the
    /// machine stopped waiting.
    func reply(_ req: Request, _ r: RelayRequest, _ decision: Decision, outcome: String, allowed: Bool,
               remember: Bool = false, delay: Int? = nil, decidedAt: PlaceMark? = nil) async -> Bool {
        await send(req, r, decision, outcome: outcome, allowed: allowed, remember: remember, delay: delay,
                   decidedAt: decidedAt) == .posted
    }

    /// `reply`, telling why a reply did not go. A request on the card whose reply did not go is
    /// opened again from the relay's text, as the core seals a request once.
    func send(_ req: Request, _ r: RelayRequest, _ decision: Decision, outcome: String, allowed: Bool,
              remember: Bool = false, delay: Int? = nil, decidedAt: PlaceMark? = nil) async -> Sent {
        let mark = decidedAt ?? placeMark()
        guard let keys = await phoneKeys() else { return .failed }
        let needsRoot = allowed && !req.items().isEmpty
        var root: Root?
        if needsRoot {
            guard let r = await vault.readRoot() else {
                show(Texts.unlockToAnswerShort)
                return .locked
            }
            root = r
        }
        guard let sealed = try? sealReply(root: root, keys: keys, request: req, decision: decision) else {
            reopen(r, keys)
            return .failed
        }
        if let h = hooks.beforeReply { await h(r.id) }
        let (sent, unsure) = await postReply(r, sealed, delay: delay, userTapped: true)
        switch sent {
        case .posted:
            await record(req, r, outcome: outcome, allowed: allowed, remember: remember, mark: mark, posted: true)
        case .gone where unsure && allowed:
            // An earlier try may have reached the relay with only its response lost, so the
            // machine may have this answer: it is recorded as given (not remembered), so that
            // leaving the place locks its machine (fail closed). The card stops waiting.
            _ = try? await db.run { try $0.closeRequest(id: r.id, outcome: "expired") }
            markExpired(r.id)
            await notifier.remove(ids: [r.id])
            await record(req, r, outcome: outcome, allowed: allowed, remember: false, mark: mark, posted: false)
        case .failed:
            reopen(r, keys)
        case .gone, .locked:
            break
        }
        return sent
    }

    /// Opens a request on the card again from the relay's text: the core seals a request once.
    func reopen(_ r: RelayRequest, _ keys: PhoneKeys) {
        guard let i = waiting.firstIndex(where: { $0.relay.id == r.id }),
              let again = try? openRequest(keys: keys, relayMachineKey: r.machine, id: r.id, sealed: r.sealed) else { return }
        waiting[i] = waiting[i].reopened(again)
    }

    /// Records an answer the relay took (or may have taken): usage, the day and its place.
    func record(_ req: Request, _ r: RelayRequest, outcome: String, allowed: Bool, remember: Bool, mark: PlaceMark,
                posted: Bool) async {
        answeredIds.insert(r.id)
        // A place left while this was on its way: the day did not begin there after all.
        let leftBefore = mark.place != nil && placeExits != mark.exits
        let place = leftBefore ? currentPlace : mark.place
        if let h = hooks.beforeRecord { await h(r.id) }
        let result = try? await db.run {
            try $0.answered(request: req, outcome: outcome, allowed: allowed, remember: remember, placeId: place,
                            utcOffsetSecs: utcOffset())
        }
        if posted { _ = try? await db.run { try $0.closeRequest(id: r.id, outcome: "answered") } }
        if result?.firstOfDay == true { Task { await self.firstApprovalOfDay() } }
        await refreshState()
        scheduleUpload(after: 10)
        // Checked once the day is in `local`: an exit from here on finds the day and locks the
        // machine itself. An exit before it could not, and a lock it sent may have reached the
        // machine before this answer did (SPEC.md 11.9).
        if allowed, mark.place != nil, placeExits != mark.exits, let m = machine(r.machine) {
            await lock(m, reason: "place")
        }
    }

    /// The time a reply may still go, on this phone's clock.
    func deadline(_ r: RelayRequest) -> Int64 {
        waiting.first { $0.relay.id == r.id }?.deadline
            ?? Waiting.deadline(seenAt: now(), created: r.created, expires: r.expires)
    }

    /// Posts a reply with the retries of 8.5: 1, 2, 4 s, then every 10 s until the deadline.
    func post(_ r: RelayRequest, _ sealed: String, delay: Int?, userTapped: Bool) async -> Sent {
        await postReply(r, sealed, delay: delay, userTapped: userTapped).sent
    }

    /// `post`, also telling whether a try before the last may have reached the relay (no
    /// answer, or a `5xx`): a later `404 gone` may then be the relay saying it already has it.
    func postReply(_ r: RelayRequest, _ sealed: String, delay: Int?, userTapped: Bool) async -> (sent: Sent, unsure: Bool) {
        let backoff: [Double] = [1, 2, 4]
        var unsure = false
        var attempt = 0
        let until = deadline(r)
        // `try? Task.sleep` returns at once in a cancelled task: stop then, or this spins until `expires`.
        while now() < until && !Task.isCancelled {
            do {
                var error: Error?
                do {
                    try await relay.reply(id: r.id, sealed: sealed, delay: delay, userTapped: userTapped)
                } catch let e {
                    error = e
                }
                if let h = hooks.afterReplyCall { error = await h(r.id, error) }
                if let error { throw error }
                relayOk()
                return (.posted, unsure)
            } catch let e as RelayError {
                if e.code == "gone" {
                    _ = try? await db.run { try $0.closeRequest(id: r.id, outcome: "expired") }
                    markExpired(r.id)
                    await notifier.remove(ids: [r.id])
                    return (.gone, unsure)
                }
                relayFailed(e)
                if case .rateLimited = e { return (.failed, unsure) }
                if (400..<500).contains(e.status) { return (.failed, unsure) }
                unsure = true
            } catch {
                relayFailed(error)
                unsure = true
            }
            try? await Task.sleep(for: .seconds(attempt < backoff.count ? backoff[attempt] : 10))
            attempt += 1
        }
        return (now() >= until ? .gone : .failed, unsure)
    }

    // MARK: levels 2 and 3 (9.6)

    /// A wrong number: refuse with `no_match` and hold the machine for an hour.
    public func wrongNumber(_ w: Waiting) async {
        let w = current(w)
        _ = await answerCard(w) { await send(w.request, w.relay, .refuse(err: .noMatch), outcome: "denied", allowed: false) }
        await applyLocal(.setHold(hold: Hold(machine: w.machine.key, until: UInt64(clockNow() + 3_600_000))))
        drop(w.relay.id)
    }

    public func releaseHold(_ machine: String) async { await applyLocal(.clearHold(machine: machine)) }

    /// Denies a sensitive request (Deny, "I don't see a number").
    public func deny(_ w: Waiting) async {
        let w = current(w)
        _ = await answerCard(w) { await send(w.request, w.relay, .deny, outcome: "denied", allowed: false) }
        drop(w.relay.id)
        await notifier.remove(ids: [w.relay.id])
    }

    /// Refuses a sensitive request for a reason (no biometrics, unsupported).
    public func refuse(_ w: Waiting, _ err: RefuseReason) async {
        let w = current(w)
        _ = await answerCard(w) { await send(w.request, w.relay, .refuse(err: err), outcome: "denied", allowed: false) }
        drop(w.relay.id)
        await notifier.remove(ids: [w.relay.id])
    }

    /// The level 3 delay in seconds (shortened only in debug builds that ask for it).
    public func delaySecs(_ verdictDelay: Int) -> Int {
        verdictDelay > 0 && config.testDelaySecs > 0 ? config.testDelaySecs : verdictDelay
    }

    /// Two hours: a level 3 approval away from a trusted place (9.6).
    public static let levelThreeDelaySecs = 7200

    /// The delay of a confirm, decided when the person confirms: the two hours at level 3
    /// unless the place the phone is in now lifts them, and never less than the verdict's
    /// from when the request arrived (the phone may have left the place, or the place been
    /// removed, while the card was open) (9.6).
    public static func confirmDelay(arrival: Int, level: Int, liftedNow: Bool) -> Int {
        max(arrival, level >= 3 && !liftedNow ? levelThreeDelaySecs : 0)
    }

    /// After biometrics: answers a level 2 or 3 request. `unseal` signs the plan, with the
    /// not-before time two hours on away from a trusted place.
    public func confirmSensitive(_ w: Waiting) async -> Bool {
        let w = current(w)
        // One reading of the place, for both the delay and the reply.
        let place = placeKind()
        let lifted = place == .trusted && placeSettledNow()
        switch w.verdict.kind {
        case .unseal:
            let delay = delaySecs(Self.confirmDelay(arrival: Int(w.verdict.delaySecs), level: Int(w.verdict.level),
                                                    liftedNow: lifted))
            let notBefore = clockNow() + Int64(delay) * 1000
            let sent = await answerCard(w) {
                await send(w.request, w.relay, .plan(place: place, notBefore: UInt64(notBefore)), outcome: "confirmed",
                           allowed: true, delay: delay > 0 ? delay : nil)
            }
            guard sent == .posted else { return false }
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
            let ok = await answerCard(w) {
                await send(w.request, w.relay, .once(place: place), outcome: "confirmed", allowed: true)
            } == .posted
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

    /// Brings the delayed records up to the relay's list. False when the relay could not be asked.
    @discardableResult
    public func refreshDelayed() async -> Bool {
        guard await phoneKeys() != nil, let list = try? await relay.listDelayed() else { return false }
        for d in list {
            if let mine = local.delayed.first(where: { $0.id == d.id }) {
                if mine.state != d.state && mine.state != "cancelled" {
                    var m = mine
                    m.state = d.state
                    if d.state == "cancelled" { m.cancelledBy = d.by }
                    await applyLocal(.putDelayed(action: m))
                    if d.state == "cancelled" { await notifier.remove(ids: ["ready-\(d.id)"]) }
                } else if mine.state == "cancelled" && mine.cancelledBy == "phone"
                            && (d.state == "waiting" || d.state == "released") && cancelResends.due(d.id, now: now()) {
                    // Cancelled here while the relay did not answer: it still holds the record. Not
                    // tapped now, so the rate-limit window holds it back too.
                    var failure: Error?
                    do { try await relay.cancelDelayed(d.id, userTapped: false) } catch { failure = error }
                    cancelResends.answered(d.id, error: failure, now: now())
                }
            } else {
                await applyLocal(.putDelayed(action: DelayedAction(
                    id: d.id, what: d.machine != nil ? "unseal_all" : "unknown", machine: d.machine,
                    releaseAt: UInt64(clamping: d.releaseAt), expires: UInt64(clamping: d.expires), state: d.state,
                    cancelledBy: d.state == "cancelled" ? d.by : nil)))
            }
        }
        await cancelPlansOfCancelledDelays()
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
        return true
    }

    /// A plan waiting on a delayed record that was cancelled is cancelled too, however the
    /// cancel arrived, so it never hands out keys (9.6, 11.23).
    func cancelPlansOfCancelledDelays() async {
        let cancelled = Set(local.delayed.filter { $0.state == "cancelled" }.map(\.id))
        for var p in local.plans where p.state != "cancelled" && (p.delayId.map(cancelled.contains) ?? false) {
            p.state = "cancelled"
            await applyLocal(.putPlan(plan: p))
        }
    }

    /// Cancel needs no biometrics: stopping is always allowed. The cancel is recorded here
    /// first, so the plan hands out no more keys whatever the relay answers: `404 gone` (the
    /// machine already fetched the record, or it expired) or no answer at all (fail closed). A
    /// cancel the relay did not get is sent again from its list (`refreshDelayed`). Returns
    /// whether the relay took it.
    @discardableResult
    public func cancelDelayed(_ id: String) async -> Bool {
        let d = local.delayed.first { $0.id == id }
        if var m = d, m.state != "cancelled" {
            m.state = "cancelled"
            m.cancelledBy = "phone"
            await applyLocal(.putDelayed(action: m))
        }
        for var p in local.plans where p.delayId == id && p.state != "cancelled" {
            p.state = "cancelled"
            await applyLocal(.putPlan(plan: p))
        }
        await notifier.remove(ids: ["ready-\(id)"])
        delayedTick = nowMs()
        var took = true
        do {
            try await relay.cancelDelayed(id)
        } catch {
            relayFailed(error)
            took = false
        }
        Task {
            await self.sendNotice(what: d?.what ?? "unseal_all", state: "cancelled", machine: d?.machine, delayId: id,
                                  at: d.map { Int64($0.releaseAt) })
        }
        return took
    }

    /// Starts a level 3 action on the phone: nil (go ahead now) at a trusted place, else the
    /// delayed record the relay keeps for the hour.
    public func startPhoneAction(_ what: String) async throws -> DelayedAction? {
        await freshClockAtHandAddedPlace()
        if delayLifted() { return nil }
        let delay = delaySecs(Self.levelThreeDelaySecs)
        let id = randomId()
        let d = try await relay.addDelayed(id: id, delay: delay)
        let action = DelayedAction(id: id, what: what, machine: nil, releaseAt: UInt64(clamping: d.releaseAt),
                                   expires: UInt64(clamping: d.expires),
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
                await notifier.remove(ids: ["ready-\(id)"])
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
                                                                  at: at.map { UInt64(clamping: $0) }, report: report)))
            if let sealed = try? sealMachineMessage(keys: keys, machineKey: m.key, machineBoxKey: m.boxKey, message: msg) {
                _ = try? await relay.postMessage(machine: m.key, sealed: sealed)
            }
        }
    }

    func nextSeq(_ machine: String) async -> UInt64 {
        (try? await db.run { try $0.nextMessageSeq(machine: machine) }) ?? UInt64(nowMs())
    }
}

/// The cancels this phone sends again from the relay's list, for this run of the app (SPEC.md
/// 11.23; client loops pause after an error and honour `429`). A cancel the relay took, or one
/// that got an answer that will not change (`404 gone`: the record is gone; `403`; `409`; any
/// other `4xx`), is not sent again. A `429` waits out its window (`retryAfter`); no answer, a
/// `5xx` or a `401` waits 15 s, twice as long after each further failure, at most 15 minutes.
struct CancelResends {
    private var done: Set<String> = []
    /// Per id: when the next try may go out, and the failures so far.
    private var waits: [String: (at: Int64, failures: Int)] = [:]

    func due(_ id: String, now: Int64) -> Bool {
        !done.contains(id) && now >= (waits[id]?.at ?? 0)
    }

    mutating func answered(_ id: String, error: Error?, now: Int64) {
        let failures = waits[id]?.failures ?? 0
        if error.map(Self.isFinal) ?? true {
            done.insert(id)
            waits[id] = nil
        } else if case .rateLimited(let until, _)? = error as? RelayError {
            waits[id] = (max(until, now), failures)
        } else {
            waits[id] = (now + Self.backoffMs(failures + 1), failures + 1)
        }
    }

    /// An answer the same call would get again.
    static func isFinal(_ error: Error) -> Bool {
        switch error as? RelayError {
        case .http(let status, _, _)?: return (400...499).contains(status) && ![401, 408, 429].contains(status)
        case .conflict?: return true
        default: return false
        }
    }

    /// The wait after `failures` tries with no usable answer: 15 s doubling, at most 15 minutes.
    static func backoffMs(_ failures: Int) -> Int64 {
        min(Int64(15_000) << Int64(min(max(failures - 1, 0), 6)), 15 * 60_000)
    }
}
