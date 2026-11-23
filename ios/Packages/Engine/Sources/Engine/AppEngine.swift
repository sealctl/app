import Foundation
import EngineKit
import Network
import Observation
import Places
import Relay
import SealCore
import UserNotifications
import Vault

/// The app model (SPEC.md 6.1, 6.3): the approval path, sync and everything that talks to
/// the relay. One per process. UI code reads its observable state and calls its methods;
/// Rust calls go through the `Database` actor, the network through the `RelayClient` actor.
@MainActor
@Observable
public final class AppEngine {
    public let vault: Vault
    public let db: Database
    public let relay: RelayClient
    public let files: SharedFiles
    public let notifier: Notifier
    public let config: EngineConfig
    @ObservationIgnored public var places: PlacesProvider?

    public internal(set) var phase: Phase = .loading
    public internal(set) var state: AppState
    public internal(set) var local: LocalState
    public internal(set) var waiting: [Waiting] = []
    public internal(set) var banners = Banners()
    public var toast: Toast?
    public internal(set) var foreground = false
    /// The trusted place the phone is inside, from region monitoring.
    public var currentPlace: String?
    /// A place candidate to offer ("Trust this place?").
    public var placeOffer: PlaceCandidate?
    /// Machines the relay lists as paired, for Leave sealctl (11.22 step 2).
    public internal(set) var relayMachines: Set<String>?
    public internal(set) var notificationsAllowed = true
    public internal(set) var biometryName = "Face ID"
    /// Bumped when a delayed record changes, so countdown screens refresh.
    public internal(set) var delayedTick: Int64 = 0
    /// The words, while one of the words screens is open.
    public let words: WordsSession
    /// A request the card should show first (from a notification tap).
    public var focusRequest: String?

    @ObservationIgnored var phoneKeysCache: PhoneKeys?
    @ObservationIgnored let keyBox: KeyBox
    @ObservationIgnored var assemblers: [String: PlanAssembler] = [:]
    @ObservationIgnored let approvals = SerialQueue()
    @ObservationIgnored var socket: PhoneSocket?
    @ObservationIgnored var uploadTask: Task<Void, Never>?
    @ObservationIgnored var onWifi = false
    @ObservationIgnored var pathMonitor: NWPathMonitor?
    @ObservationIgnored var expiryTasks: [String: Task<Void, Never>] = [:]
    /// Request ids answered by this process, so a push for them shows nothing (8.3).
    @ObservationIgnored var answeredIds: Set<String> = []
    /// Requests whose answer is on its way: a second tap waits for nothing, and the expiry
    /// timer leaves the card to the answer (SPEC.md 8.5).
    @ObservationIgnored var answering: Set<String> = []
    /// Exits from trusted places so far, to tell whether one came while an answer was on its way.
    @ObservationIgnored var placeExits = 0
    /// Test seams; always empty in the app.
    @ObservationIgnored var hooks = EngineHooks()
    /// The phone's clock for a request's time (deadlines, the card's timer, catch-up). A test
    /// sets it to move time on; the app never does.
    @ObservationIgnored var clock: () -> Int64 = { nowMs() }

    /// Now, on this phone's clock, for a request's time.
    func now() -> Int64 { clock() }

    public init(vault: Vault, db: Database, config: EngineConfig, files: SharedFiles, notifier: Notifier,
                places: PlacesProvider?) async {
        self.vault = vault
        self.db = db
        self.config = config
        self.files = files
        self.notifier = notifier
        self.places = places
        state = (try? await db.run { try $0.snapshot() }) ?? Self.emptyState
        local = (try? await db.run { try $0.local() }) ?? Self.emptyLocal
        words = WordsSession()
        let box = KeyBox(vault: vault)
        keyBox = box
        relay = RelayClient(baseURL: config.relayURL, keys: { await box.get() })
        words.engine = self
        biometryName = await vault.biometryName()
        watchNetwork()
    }

    // MARK: keys

    public func phoneKeys() async -> PhoneKeys? {
        if let k = phoneKeysCache { return k }
        let k = await vault.readPhoneKeys()
        phoneKeysCache = k
        return k
    }

    public func forgetPhoneKeys() {
        phoneKeysCache = nil
        keyBox.forget()
    }

    /// Runs `block` with the root. Nil while the phone is locked.
    func withRoot<T>(_ block: (Root) throws -> T) async -> T? {
        guard let root = await vault.readRoot() else { return nil }
        return try? block(root)
    }

    // MARK: state

    public func refreshState() async {
        if let s = try? await db.run({ try $0.snapshot() }) { state = s }
        if let l = try? await db.run({ try $0.local() }) { local = l }
        writeSnapshot()
    }

    /// `rescheduleUpload: false` inside an upload, which must not cancel itself.
    public func apply(_ event: Event, upload: Bool = false, rescheduleUpload: Bool = true) async {
        if let s = try? await db.run({ try $0.apply(event: event) }) { state = s }
        if let l = try? await db.run({ try $0.local() }) { local = l }
        writeSnapshot()
        if rescheduleUpload { scheduleUpload(after: upload ? 0 : 10) }
    }

    public func applyLocal(_ event: LocalEvent) async {
        if let l = try? await db.run({ try $0.applyLocal(event: event) }) { local = l }
        writeSnapshot()
    }

    /// The extension's snapshot, after every change (6.4).
    func writeSnapshot() {
        // A trusted place removed here or by a merge sends no exit event: it stops counting now.
        if let c = currentPlace, !state.places.contains(where: { $0.id == c && !$0.deleted }) { currentPlace = nil }
        guard phase == .ready || { if case .onboarding = phase { return true }; return false }() else { return }
        files.writeSnapshot(ExtensionSnapshot(state: state, local: local, currentPlace: currentPlace,
                                              placesOn: places?.hasForeground ?? false, relay: config.relayURL))
    }

    public var liveMachines: [Machine] { state.machines.filter { !$0.deleted } }

    public func machine(_ key: String) -> Machine? { liveMachines.first { $0.key == key } }

    public func displayName(_ m: Machine) -> String { machineDisplayName(machine: m) }

    public func show(_ text: String) { toast = Toast(text: text) }

    // MARK: phase (6.1)

    public func computePhase() async {
        await refreshState()
        if !(await vault.isDeviceSecure()) {
            phase = .needsScreenLock
            return
        }
        if await vault.hasPhoneKeys() {
            if !(await vault.hasRoot()) {
                phase = .wordsLost(reason: .passcodeRemoved)
                return
            }
            if case .wordsLost = phase { return }
            let w = state.words
            let step = Int(local.onboardingStep)
            if w == nil && !UserDefaults.standard.bool(forKey: Self.installedKey) && step == 0 {
                phase = .reinstalled
            } else if w == nil || w!.writtenOn.isEmpty {
                phase = .cardUnchecked
            } else if (7...10).contains(step) {
                phase = .onboarding(step: step)
            } else {
                phase = .ready
            }
            UserDefaults.standard.set(true, forKey: Self.installedKey)
            writeSnapshot()
            return
        }
        // No keys: a fresh install. Keys found on a later launch without this mark survived a
        // reinstall (7.4).
        UserDefaults.standard.set(true, forKey: Self.installedKey)
        if let item = await vault.readSyncBackup(), let decoded = try? backupItemDecode(bytes: item) {
            phase = .backupFound(fingerprint: decoded.fingerprint, created: Int64(decoded.created))
        } else {
            phase = .noWords
        }
    }

    static let installedKey = "com.sealctl.installed"

    /// "Continue with words 7Hq3" after a reinstall: keep the items and bring the state back.
    public func continueAfterReinstall() async -> Bool {
        guard await vault.authenticateOwner(reason: "Face ID protects showing and changing your 24 words.") == .passed else {
            return false
        }
        UserDefaults.standard.set(true, forKey: Self.installedKey)
        _ = await download()
        await refreshMachines()
        if state.words == nil, let root = await vault.readRoot() {
            let fp = fingerprint(root: root)
            await apply(.setWords(words: WordsInfo(fingerprint: fp, writtenOn: Texts.isoDate(nowMs()), lastCheck: nil,
                                                    retired: [], updated: 0)))
        }
        await computePhase()
        return true
    }

    /// The other answer: delete the items and start again.
    public func startOverAfterReinstall() async {
        await vault.erase()
        forgetPhoneKeys()
        UserDefaults.standard.set(true, forKey: Self.installedKey)
        await computePhase()
    }

    // MARK: foreground: socket and catch-up (8.3)

    public func onForeground() async {
        foreground = true
        notificationsAllowed = await notifier.allowed()
        biometryName = await vault.biometryName()
        guard phase == .ready, !relayDataDeleted, let _ = await phoneKeys() else { return }
        await takeInbox()
        if socket == nil {
            socket = PhoneSocket(
                client: relay,
                onMessage: { [weak self] o in await self?.onSocketMessage(o) },
                onConnected: { [weak self] in _ = await self?.catchUp() },
                onState: { [weak self] ok in await self?.socketState(ok) })
        }
        await socket?.start()
        await catchUp()
        await refreshStatus()
        await refreshDelayed()
        await refreshMachines()
        if nowMs() - Int64(local.lastDownload) > 3_600_000 { _ = await download() }
        if local.dirty { scheduleUpload(after: 0) }
        await notifier.removeStale(now: nowMs(), answered: answeredIds)
        await registerPush()
    }

    /// Leave sealctl from step 5 on: the relay data is being deleted or is gone, so foreground
    /// work does not call the relay, which would only be refused or bring the phone back (11.22).
    var relayDataDeleted: Bool { local.leaveStep >= 5 }

    public func onBackground() async {
        foreground = false
        await socket?.stop()
        socket = nil
        await updateBadge()
    }

    func socketState(_ ok: Bool) {
        if !ok && !banners.offline { banners.relayDown = true } else if ok { banners.relayDown = false }
    }

    func onSocketMessage(_ o: JSON) async {
        switch o["type"].str {
        case "request": await handle(RelayRequest(json: o), fromPush: false)
        case "status": await refreshStatus()
        case "delayed": await refreshDelayed()
        case "cancelled":
            let id = o["id"].str
            if var d = local.delayed.first(where: { $0.id == id }) {
                d.state = "cancelled"
                d.cancelledBy = o["by"].string
                await applyLocal(.putDelayed(action: d))
                await notifier.remove(ids: ["ready-\(id)"])
            }
            if var p = local.plans.first(where: { $0.delayId == id }) {
                p.state = "cancelled"
                await applyLocal(.putPlan(plan: p))
            }
            await refreshDelayed()
        default: break
        }
    }

    /// Lists pending requests and handles each (after a push, on foreground, on reconnect).
    /// False when the relay could not be asked.
    @discardableResult
    public func catchUp(fromPush: Bool = false) async -> Bool {
        guard !relayDataDeleted, await phoneKeys() != nil else { return false }
        // A request seen after this was asked for (by the socket) may be newer than the list.
        let asked = now()
        let list: [RelayRequest]
        do {
            list = try await relay.requests()
            relayOk()
        } catch {
            relayFailed(error)
            return false
        }
        if let h = hooks.afterRequestList { await h() }
        for r in list { await handle(r, fromPush: fromPush) }
        // Requests that left the relay list expired or were answered elsewhere.
        let ids = Set(list.map(\.id))
        let t = now()
        var gone: [String] = []
        waiting = waiting.map { w in
            var w = w
            if !ids.contains(w.relay.id) && !w.expired && !answering.contains(w.relay.id)
                && (w.deadline < t || w.seenAt < asked) {
                gone.append(w.relay.id)
                w.expired = true
            }
            return w
        }
        if !gone.isEmpty { await notifier.remove(ids: gone) }
        await updateBadge()
        return true
    }

    func relayOk() {
        banners.relayDown = false
        banners.offline = false
        banners.clockSkew = false
    }

    func relayFailed(_ error: Error) {
        guard let e = error as? RelayError else { return }
        switch e {
        case .clockSkew: banners.clockSkew = true
        case .rateLimited(let until, _): banners.rateLimitedUntil = until
        case .http(let status, _, _):
            if status == 401 { banners.signatureRefused = true } else if status >= 500 { banners.relayDown = true }
        case .transport: if !banners.offline { banners.relayDown = true }
        default: break
        }
        Log.note("relay call failed: \(e.code)")
    }

    func updateBadge() async {
        await notifier.setBadge(waiting.filter { !$0.expired && $0.verdict.asking == .oneTap }.count)
    }

    // MARK: the extension's inbox (6.4)

    /// Records what the extension answered by itself while the app was not running. The app
    /// may run hours later, after the signed time has left its 10-minute window, so each item
    /// is opened and recorded at the time the extension answered it.
    func takeInbox() async {
        guard let keys = await phoneKeys() else { return }
        for item in files.takeInbox() {
            answeredIds.insert(item.id)
            _ = try? await db.run { try $0.seeRequest(id: item.id, machine: item.machine, expires: UInt64(item.time + 600_000)) }
            let at = UInt64(max(item.time, 0))
            if let req = try? openAnsweredRequest(keys: keys, relayMachineKey: item.machine, id: item.id,
                                                  sealed: item.sealed, answeredAt: at) {
                if item.outcome == "report" {
                    let result = try? await db.run { try $0.applyReportAt(request: req, utcOffsetSecs: utcOffset(), receivedAt: at) }
                    if let h = result?.handback { reportArrived(h) }
                } else {
                    let r = try? await db.run {
                        try $0.answeredAt(request: req, outcome: item.outcome, allowed: item.allowed,
                                          placeId: item.placeId, utcOffsetSecs: utcOffset(), answeredAt: at)
                    }
                    if r?.firstOfDay == true { Task { await self.firstApprovalOfDay() } }
                }
            }
            _ = try? await db.run { try $0.closeRequest(id: item.id, outcome: "answered") }
        }
        await refreshState()
    }

    // MARK: network (8.6)

    func watchNetwork() {
        let m = NWPathMonitor()
        m.pathUpdateHandler = { [weak self] path in
            let up = path.status == .satisfied
            let wifi = up && (path.usesInterfaceType(.wifi) || path.usesInterfaceType(.wiredEthernet))
            Task { @MainActor [weak self] in
                guard let self else { return }
                let wasOffline = self.banners.offline
                self.banners.offline = !up
                self.onWifi = wifi
                if up && wasOffline && self.foreground { _ = await self.catchUp() }
            }
        }
        m.start(queue: DispatchQueue(label: "sealctl.network"))
        pathMonitor = m
    }

    // MARK: empty records

    public static let emptyState = AppState(machines: [], answers: [], places: [], inventory: [], summaries: [], words: nil,
                                            settings: AppSettings(relayBackup: true, keychainBackup: true, updated: 0), reports: [])

    public static let emptyLocal = LocalState(
        days: [], pending: [], holds: [], plans: [], delayed: [], candidates: [],
        device: DeviceInfo(deviceId: "", token: nil, platform: "apns", sandbox: true, registered: 0),
        onboardingStep: 0, stateRev: 0, lastDownload: 0, lastUpload: 0, dirty: false, agentNoteShown: false,
        messageSeq: [], backupShortened: false, leaveStep: 0, leaveSkipped: [])
}

/// Points where a test holds the engine to put events in a set order (never set in the app).
struct EngineHooks {
    /// Before a reply is posted, with the request id.
    var beforeReply: (@MainActor (String) async -> Void)?
    /// After `catchUp` has the relay's list, before it handles it.
    var afterRequestList: (@MainActor () async -> Void)?
    /// After each reply call, with the request id and the call's error (nil when the relay took
    /// it); returns the error the engine sees instead, as when a response is lost on its way back.
    var afterReplyCall: (@MainActor (String, Error?) async -> Error?)?
    /// After the relay took a reply, once the place it counts for is chosen, before it is recorded.
    var beforeRecord: (@MainActor (String) async -> Void)?
}

/// The phone keys for the relay client's signing closure.
final class KeyBox: @unchecked Sendable {
    let vault: Vault
    private let lock = NSLock()
    private var cached: PhoneKeys?

    init(vault: Vault) { self.vault = vault }

    func get() async -> PhoneKeys? {
        if let c = lock.withLock({ cached }) { return c }
        let k = await vault.readPhoneKeys()
        lock.withLock { cached = k }
        return k
    }

    func forget() { lock.withLock { cached = nil } }
}
