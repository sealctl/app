import Foundation
import Network
import Relay
import SealCore
import UserNotifications
import Vault

/// Whether the phone is on Wi-Fi or Ethernet now (SPEC.md 9.3: `near` counts only there).
public func onWifiNow(timeout: Duration = .milliseconds(300)) async -> Bool {
    let monitor = NWPathMonitor()
    let result = Box(false)
    let queue = DispatchQueue(label: "sealctl.path")
    let done = Box(false)
    monitor.pathUpdateHandler = { path in
        result.value = path.status == .satisfied && (path.usesInterfaceType(.wifi) || path.usesInterfaceType(.wiredEthernet))
        done.value = true
    }
    monitor.start(queue: queue)
    let start = ContinuousClock.now
    while !done.value && ContinuousClock.now - start < timeout {
        try? await Task.sleep(for: .milliseconds(20))
    }
    monitor.cancel()
    return result.value
}

final class Box<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: T
    init(_ v: T) { _value = v }
    var value: T {
        get { lock.lock(); defer { lock.unlock() }; return _value }
        set { lock.lock(); _value = newValue; lock.unlock() }
    }
}

/// The Notification Service Extension's work (SPEC.md 10.1): open the pushed request with the
/// phone keys, answer it when `decide` says Automatic and the root can be read, otherwise
/// rewrite the notification with the request's own text and buttons. Any failure leaves the
/// push as the relay sent it.
public struct ExtensionHandler: Sendable {
    public let vault: Vault
    public let files: SharedFiles

    public init(vault: Vault, files: SharedFiles) {
        self.vault = vault
        self.files = files
    }

    /// Returns the content to deliver, or nil to deliver the push unchanged.
    public func handle(_ content: UNMutableNotificationContent) async -> UNNotificationContent? {
        let info = content.userInfo
        guard (info["type"] as? String) == "request", let id = info["id"] as? String else { return nil }
        // Before the first unlock since boot the phone keys can't be read.
        guard let keys = await vault.readPhoneKeys(), let snap = files.readSnapshot(), let state = snap.decodedState() else {
            return nil
        }
        let relay = RelayClient(baseURL: snap.relay, keys: { keys })
        guard let list = try? await relay.requests() else { return nil }
        guard let r = list.first(where: { $0.id == id }) else {
            content.title = Texts.requestTitle
            content.body = "It stopped waiting."
            content.interruptionLevel = .passive
            content.sound = nil
            return content
        }
        guard let machine = state.machines.first(where: { $0.key == r.machine && !$0.deleted }),
              let req = try? openRequest(keys: keys, relayMachineKey: r.machine, id: r.id, sealed: r.sealed)
        else { return nil }
        let name = machineDisplayName(machine: machine)
        let biometry = await vault.biometryName()
        let now = nowMs()
        let status = machine.lastStatus
        let open = status.map { s in
            s.session == "open" && (s.left.map { now - Int64(s.reportedAt) < Int64($0) * 1000 } ?? false)
        } ?? false
        let ctx = DecideContext(
            now: UInt64(now), utcOffsetSecs: Int32(TimeZone.current.secondsFromGMT()),
            phoneUnlocked: await vault.canReadRoot(), near: r.near, onWifi: await onWifiNow(),
            placesOn: snap.placesOn, currentPlace: snap.currentPlace, day: snap.day(r.machine),
            answers: state.answers.filter { !$0.deleted }, sessionOpen: open, hold: snap.hold(r.machine),
            biometrics: await vault.biometrics(), plan: snap.plan(r.machine))
        let verdict = decide(request: req, ctx: ctx)
        let placeName = snap.currentPlace.flatMap { id in state.places.first { $0.id == id && !$0.deleted }?.name }

        switch verdict.asking {
        case .automatic:
            guard let d = verdict.automatic, let root = await vault.readRoot(),
                  let sealed = try? sealReply(root: root, keys: keys, request: req, decision: d),
                  (try? await relay.reply(id: r.id, sealed: sealed, userTapped: false)) != nil
            else { break }
            files.writeInbox(InboxItem(id: r.id, machine: r.machine, sealed: r.sealed, outcome: "automatic", allowed: true,
                                       placeId: snap.currentPlace, time: now))
            return Notes.passive(Texts.answeredByItself(name, place: placeName), userInfo: ["answered": r.id])
        case .planKeys:
            guard let plan = snap.plan(r.machine), let root = await vault.readRoot() else { break }
            let approval = PlanApproval(machine: plan.machine, hash: plan.planHash, notBefore: plan.notBefore,
                                        keys: plan.keys.map { KeyRef(purpose: $0.purpose, id: $0.id) })
            guard let sealed = try? sealPlanKeysReply(root: root, keys: keys, request: req, approval: approval),
                  (try? await relay.reply(id: r.id, sealed: sealed, userTapped: false)) != nil else { break }
            files.writeInbox(InboxItem(id: r.id, machine: r.machine, sealed: r.sealed, outcome: "in_session", allowed: true,
                                       placeId: snap.currentPlace, time: now))
            return Notes.passive(Texts.answeredByItself(name, place: placeName), userInfo: ["answered": r.id])
        case .refused:
            let err = verdict.refuse ?? .unsupported
            if let sealed = try? sealReply(root: nil, keys: keys, request: req, decision: .refuse(err: err)) {
                _ = try? await relay.reply(id: r.id, sealed: sealed, userTapped: false)
                files.writeInbox(InboxItem(id: r.id, machine: r.machine, sealed: r.sealed, outcome: "denied", allowed: false,
                                           placeId: nil, time: now))
            }
            switch err {
            case .notNear: return Notes.active(Texts.notNear(name), userInfo: ["answered": r.id])
            case .noBiometrics: return Notes.active(Texts.noBiometrics(biometry), userInfo: ["answered": r.id])
            default:
                return Notes.passive(Texts.stoppedWaiting(name), userInfo: ["answered": r.id])
            }
        case .silent:
            // A report: acknowledged here, recorded by the app from the inbox at its next run.
            guard req.kind() == .report,
                  let sealed = try? sealReportReply(keys: keys, request: req, ack: req.status()?.seq, messages: []),
                  (try? await relay.reply(id: r.id, sealed: sealed, userTapped: false)) != nil else { break }
            files.writeInbox(InboxItem(id: r.id, machine: r.machine, sealed: r.sealed, outcome: "report", allowed: false,
                                       placeId: nil, time: now))
            if let h = req.handback() {
                let done = h.items.filter { $0.state == "done" }.count
                let failed = h.items.filter { $0.state == "failed" }.count
                return Notes.active(Texts.handedBack(name, done: done, failed: failed), userInfo: ["answered": r.id])
            }
            return Notes.passive(name, body: "Reported.", userInfo: ["answered": r.id])
        case .oneTap, .inApp:
            break
        }
        let w = Waiting(relay: r, request: req, verdict: verdict, machine: machine, seenAt: now, plan: req.plan())
        Notes.fill(content, w, machineName: name, biometry: biometry)
        return content
    }
}
