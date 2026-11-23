import DesignSystem
import Engine
import EngineKit
import Places
import Relay
import SealCore
import SwiftUI
import UIKit
import Vault

/// Settings (SPEC.md 11.18).
struct SettingsTab: View {
    @Environment(AppModel.self) private var model
    @Environment(Router.self) private var router
    @SwiftUI.State private var testMessage: String?
    @SwiftUI.State private var timeSensitive = true

    var body: some View {
        let e = model.engine!
        let s = e.state
        Page("Settings", onBack: nil) {
            SectionLabel("Words")
            if let w = s.words {
                HStack(spacing: 0) {
                    Text("Words ").foregroundStyle(Palette.ink2)
                    MonoText(w.fingerprint, weight: .semibold)
                    Text(" · written on \(w.writtenOn) · next check \(addDays(date: w.lastCheck ?? w.writtenOn, days: 365))")
                        .foregroundStyle(Palette.ink2)
                }
                .font(.subheadline)
                .accessibilityElement(children: .combine)
            }
            SecondaryButton("Show words") { router.push(.showWords) }
            SectionLabel("Backups")
            ToggleRow("iCloud Keychain", isOn: Binding(get: { s.settings.keychainBackup }, set: { on in
                Task { _ = await e.setKeychainBackup(on) }
            }))
            ToggleRow("Encrypted backup on the relay", isOn: Binding(get: { s.settings.relayBackup }, set: { on in
                Task { await e.setRelayBackup(on) }
            }))
            if e.local.lastUpload > 0 { MutedText("Saved \(Texts.ago(Int64(e.local.lastUpload)))") }
            if e.local.backupShortened { MutedText("The relay backup is full. Old inventory entries were shortened.") }
            NavRow("Places", value: "\(s.places.filter { !$0.deleted }.count)") { router.push(.places) }
            NavRow("Answers", value: "\(s.answers.filter { !$0.deleted }.count)") { router.push(.answers) }
            SectionLabel("Notifications")
            BodyText(e.notificationsAllowed ? (timeSensitive ? "On · Time Sensitive on" : "On · Time Sensitive off") : "Off")
            SecondaryButton("Send a test request") {
                Task {
                    testMessage = nil
                    testMessage = await e.testPush()
                    if testMessage == nil {
                        try? await Task.sleep(for: .seconds(30))
                    }
                }
            }
            ErrorText(testMessage)
            NavRow("Phones getting requests") { router.push(.devices) }
            SectionLabel("Relay")
            HStack(spacing: 0) {
                MonoText(e.relay.host, style: .subheadline)
                Text(e.banners.relayDown ? " · Not answering" : " · Connected").font(.subheadline).foregroundStyle(Palette.muted)
            }
            .accessibilityElement(children: .combine)
            SecondaryButton("Delete relay data and unpair") { router.push(.deleteRelay) }
            MutedText("Your machines are unpaired and the relay forgets them. Your words stay on this phone.")
            SectionLabel("This phone")
            SecondaryButton("Remove from this phone") { router.push(.erase) }
            MutedText("Your words, machines and history leave this phone. Your computers stay sealed; your card restores everything.")
            SecondaryButton("Unseal all machines and leave") { router.push(.leave) }
            MutedText("Every computer gets its passwords back, then sealctl forgets you.")
            SectionLabel("About")
            NavRow("Version \(BuildConfig.version) (\(BuildConfig.build)) · core \(coreVersion()) · protocol \(protocolVersion())") {
                router.push(.about)
            }
        }
        .task { timeSensitive = await model.notifier.timeSensitiveOn() }
    }
}

struct AboutView: View {
    @Environment(AppModel.self) private var model
    @Environment(Router.self) private var router

    var body: some View {
        Page("About", onBack: { router.pop() }) {
            Wordmark()
            BodyText("Version \(BuildConfig.version) (\(BuildConfig.build)) · core \(coreVersion()) · protocol \(protocolVersion()) · rules \(appRulesVersion())")
            MutedText("Relay \(model.engine!.relay.host)")
            NavRow("Source code") { Links.open("https://github.com/sealctl/app") }
            NavRow("Licences") { router.push(.licences) }
            NavRow("Privacy policy") { Links.open("https://sealctl.com/privacy") }
            NavRow("Terms") { Links.open("https://sealctl.com/terms") }
            NavRow("Report a security issue") { Links.open("mailto:security@sealctl.com") }
        }
    }
}

/// Licences (SPEC.md 11.18): the app's own licences, then every Rust crate in SealctlFFI with its
/// licence text (notices/rust-crates.txt, made by scripts/notices.sh with cargo-about). Same
/// header and paragraph split as Android's LicencesScreen.
struct LicencesView: View {
    @Environment(Router.self) private var router
    /// One block per paragraph, so no single Text is thousands of lines long.
    private static let blocks: [String] = {
        guard let url = Bundle.main.url(forResource: "rust-crates", withExtension: "txt"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        // Some licence texts have CRLF line ends; a Swift Character holds "\r\n" whole, so
        // normalise first or \n would not match there.
        return text.replacingOccurrences(of: "\r\n", with: "\n").split(separator: #/\n\s*\n/#)
            .map { String($0.reversed().drop(while: \.isWhitespace).reversed()) }
            .filter { !$0.allSatisfy(\.isWhitespace) }
    }()
    var body: some View {
        Page("Licences", onBack: { router.pop() }) {
            BodyText("sealctl app: AGPL-3.0. sealctl-core: MIT. Source code: github.com/sealctl/app.")
            BodyText("Swift packages: only the app's own, under AGPL-3.0.")
            BodyText("Apple frameworks: SwiftUI, UIKit, Foundation, Security, LocalAuthentication, CoreLocation, AVFoundation, UserNotifications, Network (Apple SDK terms).")
            LazyVStack(alignment: .leading, spacing: 8) {
                ForEach(Array(Self.blocks.enumerated()), id: \.offset) { _, block in
                    if block.hasPrefix("=== ") {
                        Text(verbatim: String(block.dropFirst(4))).font(.subheadline.weight(.semibold))
                            .foregroundStyle(Palette.ink).padding(.top, 12)
                    } else {
                        Text(verbatim: block).font(Fonts.mono(.caption2)).foregroundStyle(Palette.ink2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }
}

/// Answers (11.10).
struct AnswersView: View {
    @Environment(AppModel.self) private var model
    @Environment(Router.self) private var router

    var body: some View {
        let e = model.engine!
        let answers = e.state.answers.filter { !$0.deleted }
        Page("Answers", onBack: { router.pop() }) {
            if answers.isEmpty {
                MutedText("No answers yet. When you tap Allow on an agent's first use of a key, it's remembered here.")
            }
            ForEach(answers, id: \.self) { a in
                SurfaceCard {
                    (Text(verbatim: shown(Texts.agentName(a.agent), Texts.maxAgent)).bold() + Text(" may use ") + Text(verbatim: shown(a.keyName)).font(Fonts.mono())
                        + Text(" in ") + Text(verbatim: shown(a.repoName.isEmpty ? a.repoId : a.repoName)).bold())
                        .foregroundStyle(Palette.ink)
                    let left = answerDaysLeft(lastUsed: a.lastUsed, now: UInt64(nowMs()))
                    if left <= 10 {
                        Text("Unused for \(90 - left) days. Removed in \(left) days.").foregroundStyle(Palette.waiting)
                    } else {
                        MutedText("Last used \(Texts.ago(Int64(a.lastUsed)))")
                    }
                    TextButton("Remove") {
                        Task { await e.apply(.removeAnswer(agent: a.agent, keyName: a.keyName, repoId: a.repoId), upload: true) }
                    }
                    .foregroundStyle(Palette.accent)
                }
            }
            MutedText("Agents ask once per key and repository. You at the keyboard are never asked inside an Open session. A file in a repository never grants anything.")
        }
    }
}

/// Places (11.9): "Trust this place?", the list, rename and remove; no map.
struct PlacesView: View {
    @Environment(AppModel.self) private var model
    @Environment(Router.self) private var router
    @SwiftUI.State private var name = ""
    @SwiftUI.State private var removing: String?
    @SwiftUI.State private var renaming: String?
    @SwiftUI.State private var newName = ""

    var body: some View {
        let e = model.engine!
        let places = e.state.places.filter { !$0.deleted }
        Page("Places", onBack: { router.pop() }) {
            if let o = e.placeOffer {
                SurfaceCard {
                    TitleText("Trust this place?")
                    BodyText("You opened your machines here on \(o.days.count) mornings: \(o.days.joined(separator: ", ")).")
                    BodyText("At a trusted place, reopening needs no tap while your phone is unlocked and near the machine, sessions can stay open up to 4 hours, and leaving locks the machines you opened here. The location stays on this phone.")
                    TextField("Name", text: $name).textFieldStyle(.roundedBorder)
                    PrimaryButton("Trust") { Task { await e.trustPlace(o, name: name) } }
                    PlainButton("Not this place") { Task { await e.suppressPlace(o) } }
                }
            }
            if !model.places.hasForeground {
                BodyText("Places need location access. Without it, a session stays open up to 1 hour and reopening always takes a tap.")
                PrimaryButton("Allow location") {
                    Task {
                        if model.places.undetermined { await model.places.requestWhenInUse() } else { Links.settings() }
                    }
                }
            } else if places.isEmpty {
                MutedText("No places yet. After three mornings of approving at the same spot, sealctl asks whether to trust it.")
            }
            if model.places.hasForeground && e.currentPlace == nil && e.placeOffer == nil { TrustHereView() }
            ForEach(places, id: \.id) { p in
                SurfaceCard {
                    Text(p.name).fontWeight(.semibold).foregroundStyle(Palette.ink)
                    MutedText("trusted since \(Texts.isoDate(Int64(p.created)))" + (e.currentPlace == p.id ? " · You're here" : ""))
                    if p.manual && Int64(p.created) + 86_400_000 > nowMs() {
                        MutedText("Skips the two-hour wait from \(Texts.time(Int64(p.created) + 86_400_000)) tomorrow")
                    }
                    if removing == p.id {
                        BodyText("Remove \(p.name)? Machines opened here stay Open until their allowance ends.")
                        HStack {
                            TextButton("Remove") { Task { await e.removePlace(p.id); removing = nil } }
                            TextButton("Cancel") { removing = nil }
                        }
                    } else if renaming == p.id {
                        TextField("Name", text: $newName).textFieldStyle(.roundedBorder)
                        HStack {
                            TextButton("Rename") { Task { await e.renamePlace(p.id, newName); renaming = nil } }
                            TextButton("Cancel") { renaming = nil }
                        }
                    } else {
                        HStack(spacing: 20) {
                            TextButton("Rename") { newName = p.name; renaming = p.id }
                            TextButton("Remove") { removing = p.id }
                        }
                    }
                }
            }
            MutedText("Places are learned: after three mornings of approving at the same spot, sealctl asks whether to trust it. You can also trust where you are now.")
        }
        .onAppear { name = "Place \(places.count + 1)" }
    }
}

/// "Trust where I am now": a place added by hand (11.9), with biometrics. Its comforts start
/// at once; it lifts the level 3 delay only after 24 hours.
struct TrustHereView: View {
    @Environment(AppModel.self) private var model
    @SwiftUI.State private var fix: Fix?
    @SwiftUI.State private var locating = false
    @SwiftUI.State private var name = "Home"
    @SwiftUI.State private var error: String?

    var body: some View {
        let e = model.engine!
        if let f = fix {
            SurfaceCard {
                TitleText("Trust this place?")
                BodyText("From now on here: reopening your machines needs no tap while your phone is unlocked and near them, sessions can stay open up to 4 hours, and leaving locks the machines you opened here.")
                BodyText("Showing your words and leaving sealctl skip the two-hour wait here from \(Texts.time(nowMs() + 86_400_000)) tomorrow, so someone holding your unlocked phone can't trust a place to skip it.")
                MutedText("Accurate to \(Int(f.accuracy)) m. The location stays on this phone.")
                TextField("Name", text: $name).textFieldStyle(.roundedBorder)
                ErrorText(error)
                PrimaryButton("Trust") {
                    Task {
                        guard await e.vault.gate(reason: "Trust this place") == .passed else {
                            error = "Couldn't confirm it's you."
                            return
                        }
                        let n = name.trimmingCharacters(in: .whitespaces)
                        await e.apply(.addPlace(place: TrustedPlace(id: randomId(), name: n.isEmpty ? "Place" : String(n.prefix(40)),
                                                                    lat: f.lat, lon: f.lon, radius: 150, created: UInt64(nowMs()),
                                                                    updated: 0, deleted: false, manual: true)), upload: true)
                        await e.monitorPlaces()
                        fix = nil
                        e.show("Trusted \(n.isEmpty ? "Place" : n).")
                    }
                }
            }
        } else {
            SecondaryButton(locating ? "Finding where you are…" : "Trust where I am now", enabled: !locating) {
                locating = true
                error = nil
                Task {
                    let got = await model.places.sample()
                    locating = false
                    if let got, got.accuracy <= 100 {
                        fix = got
                    } else if let got {
                        error = "Your location is only accurate to \(Int(got.accuracy)) m. Try again in a moment, near a window."
                    } else {
                        error = "Couldn't get your location. Try again in a moment."
                    }
                }
            }
            ErrorText(error)
        }
    }
}

/// Phones getting requests (8.7).
struct DevicesView: View {
    @Environment(AppModel.self) private var model
    @Environment(Router.self) private var router
    @SwiftUI.State private var list: [RelayDevice]?
    @SwiftUI.State private var failed = false

    var body: some View {
        let e = model.engine!
        let mine = e.local.device.deviceId
        Page("Phones getting requests", onBack: { router.pop() }) {
            if failed {
                MutedText(Texts.relayDown)
            } else if let items = list {
                if items.isEmpty { MutedText("No phone is registered for notifications yet.") }
                ForEach(items, id: \.device) { d in
                    HStack {
                        if d.device == mine {
                            Text("This phone").foregroundStyle(Palette.ink)
                        } else {
                            let stale = nowMs() - d.updated > 30 * 86_400_000
                            Text("\(d.platform == "apns" ? "iPhone" : "Android") · " +
                                 (stale ? "Not updated since \(Texts.isoDate(d.updated))" : "updated \(Texts.ago(d.updated))"))
                                .foregroundStyle(Palette.ink)
                            Spacer()
                            TextButton("Remove") {
                                Task {
                                    try? await e.relay.deletePush(d.device)
                                    list = try? await e.relay.listPush()
                                }
                            }
                        }
                    }
                    .frame(minHeight: 44)
                }
            } else {
                ProgressView()
            }
        }
        .task {
            do { list = try await e.relay.listPush() } catch { failed = true }
        }
    }
}

// MARK: machine detail (11.17)

struct MachineDetailView: View {
    @Environment(AppModel.self) private var model
    @Environment(Router.self) private var router
    let key: String
    @SwiftUI.State private var confirmUnpair = false
    @SwiftUI.State private var nickname = ""

    var body: some View {
        let e = model.engine!
        if let m = e.state.machines.first(where: { $0.key == key && !$0.deleted }) {
            Ticker { now in
                let v = MachineView.of(m, e, now: now)
                let tag = (try? machineTag(machineKey: key)) ?? ""
                Page(onBack: { router.pop() }) {
                    HStack(spacing: 10) {
                        MonoText(shown(m.name, 0), style: .title3, weight: .semibold)
                        MonoText("#\(tag)", color: Palette.muted)
                    }
                    StateLabel(v.state.kind, v.row, spoken: v.spoken)
                    if !v.detail.isEmpty { BodyText(v.detail) }
                    if let hold = e.local.holds.first(where: { $0.machine == key && Int64($0.until) > now }) {
                        Text(Texts.held(e.displayName(m), until: Int64(hold.until))).foregroundStyle(Palette.waiting)
                        TextButton("Release now") {
                            Task {
                                if await e.vault.gate(reason: "Confirm releasing \(e.displayName(m)).") == .passed {
                                    await e.releaseHold(key)
                                }
                            }
                        }
                    }
                    if v.state == .open {
                        PrimaryButton("Lock now") {
                            Task { if await e.lock(m) { e.show("Locked \(e.displayName(m)).") } }
                        }
                    }
                    TextField("Nickname", text: $nickname).textFieldStyle(.roundedBorder)
                        .accessibilityIdentifier("Nickname")
                    if nickname != (m.nickname ?? "") {
                        SecondaryButton("Save nickname") { Task { await e.setNickname(key, nickname.isEmpty ? nil : nickname) } }
                    }
                    MutedText([m.os.nonEmpty, m.model, "paired \(Texts.isoDate(Int64(m.pairedAt)))",
                               "seen \(Texts.ago(m.lastSeen.map { Int64($0) }, now: now))"].compactMap { $0 }.joined(separator: " · "))
                    NavRow("Keys it used") { router.push(.activity(machine: key)) }
                    NavRow("What it holds") { router.push(.inventory(machine: key)) }
                    if confirmUnpair {
                        SurfaceCard {
                            TitleText("Unpair \(e.displayName(m))?")
                            BodyText("It can no longer ask this phone for keys. If it is Open, it locks the next time it reaches the relay. Its history and inventory stay on this phone.")
                            HStack(spacing: 8) {
                                PrimaryButton("Unpair") { Task { if await e.unpair(m) { router.pop() } } }
                                SecondaryButton("Cancel") { confirmUnpair = false }
                            }
                        }
                    } else {
                        SecondaryButton("Unpair") { confirmUnpair = true }
                    }
                    PlainButton("This machine was lost or stolen", color: Palette.accent) { router.push(.lostMachine(key)) }
                }
            }
            .onAppear { nickname = m.nickname ?? "" }
        } else {
            Page(onBack: { router.pop() }) { MutedText("This machine is no longer paired.") }
        }
    }
}

struct LostMachineView: View {
    @Environment(AppModel.self) private var model
    @Environment(Router.self) private var router
    let key: String
    @SwiftUI.State private var used: [(String, Int64)] = []

    var body: some View {
        let e = model.engine!
        let m = e.state.machines.first { $0.key == key }
        let held = e.state.inventory.filter { $0.machine == key && !$0.deleted && ($0.purpose == "volume" || $0.purpose == "backup") }
        Page(onBack: { router.pop() }) {
            TitleText("\(m.map { shown($0.name) } ?? "This machine") was lost or stolen")
            HStack {
                BodyText("1. Unpair it now.")
                if let m, !m.deleted {
                    TextButton("Unpair") { Task { await e.unpair(m) } }
                } else {
                    Text("Unpaired").foregroundStyle(Palette.muted)
                }
            }
            BodyText("2. Change these secrets at their providers. It used them in the last 90 days:")
            ForEach(used, id: \.0) { k, t in
                HStack(spacing: 0) {
                    MonoText(shown(k), style: .subheadline)
                    Text(" · last used \(Texts.isoDate(t))").font(.subheadline).foregroundStyle(Palette.muted)
                }
            }
            BodyText("3. Re-encrypt what it had open. On another machine that has them, run `sealctl migrate`:")
            ForEach(held, id: \.id) { i in
                MonoText("\(i.purpose == "volume" ? "Volume" : "Backup") \(shown(i.path.isEmpty ? i.id : i.path, Texts.maxLine))", style: .subheadline)
            }
            BodyText("Your words were never on that machine, so they don't need to change.")
        } bottom: {
            PrimaryButton("Done") { router.pop() }
        }
        .task {
            let since = nowMs() - 90 * 86_400_000
            let log = await e.usage(machine: key, limit: 1000).filter { Int64($0.time) > since && !$0.key.isEmpty }
            var last: [String: Int64] = [:]
            for u in log { last[u.key] = max(last[u.key] ?? 0, Int64(u.time)) }
            used = last.sorted { $0.value > $1.value }.map { ($0.key, $0.value) }
        }
    }
}

// MARK: level 3 actions on the phone (11.18, 11.19)

/// A level 3 action: biometrics, then at once at a trusted place or after the hour, then
/// biometrics again and the relay's `finish`.
struct PhoneAction<Intro: View>: View {
    @Environment(AppModel.self) private var model
    @Environment(Router.self) private var router
    let what: String
    let reason: String
    let button: String
    let intro: Intro
    let run: () async -> String?
    @SwiftUI.State private var error: String?
    @SwiftUI.State private var done: String?
    /// The delay on screen stays until closed, also after a cancel.
    @SwiftUI.State private var delayId: String?
    /// A face or fingerprint was added or removed: two card words come before a new gate (9.6).
    @SwiftUI.State private var cardCheck = false

    init(what: String, reason: String, button: String, @ViewBuilder intro: () -> Intro, run: @escaping () async -> String?) {
        self.what = what; self.reason = reason; self.button = button; self.intro = intro(); self.run = run
    }

    var body: some View {
        let e = model.engine!
        let pending = e.local.delayed.last { $0.what == what && ($0.state == "waiting" || $0.state == "released") }
        Ticker { now in
            if let done {
                Page(onBack: nil) {
                    Gap(24)
                    BodyText(done)
                } bottom: { PrimaryButton("Done") { router.pop() } }
            } else if cardCheck {
                CardWordsView(positions: 2, groups: 2, title: "Use your card", body: Texts.biometryChanged, onPassed: {
                    Task {
                        await e.vault.resetGate()
                        cardCheck = false
                        go(pending, e)
                    }
                }, onCancel: { cardCheck = false })
            } else if let id = delayId ?? pending.flatMap({ Int64($0.releaseAt) > now ? $0.id : nil }),
                      let d = e.local.delayed.first(where: { $0.id == id }),
                      (d.state == "waiting" && Int64(d.releaseAt) > now) || (d.state == "cancelled" && delayId == id) {
                DelayView(id: id, title: what == "words" ? "Showing your words" : what == "delete" ? "Deleting your relay data" : "Leaving sealctl")
                    .onAppear { if d.state == "waiting" { delayId = id } }
                    .onChange(of: d.state) { _, st in if st == "waiting" { delayId = id } }
            } else {
                Page(onBack: { router.pop() }) {
                    Gap(16)
                    intro
                    if pending == nil {
                        BodyText(e.delayLifted() ? "At your trusted place: this happens as soon as you confirm."
                                 : "This starts two hours after you confirm. Your phone and your computers can cancel it until then.")
                    } else {
                        BodyText("The hour is over. Confirm again to finish.")
                    }
                } bottom: {
                    ErrorText(error)
                    PrimaryButton(pending != nil ? "Finish" : button) { go(pending, e) }
                    PlainButton("Cancel") { router.pop() }
                }
            }
        }
    }

    private func go(_ pending: DelayedAction?, _ e: AppEngine) {
        Task {
            error = nil
            switch await e.vault.gate(reason: reason) {
            case .passed: break
            case .cancelled: return
            case .lockedOut: error = Texts.lockedOut(e.biometryName); return
            case .unavailable: error = Texts.noBiometrics(e.biometryName); return
            case .changed: cardCheck = true; return
            case .failed(let m): error = "Couldn't confirm (\(m))."; return
            }
            if let pending {
                switch await e.finishPhoneAction(pending.id) {
                case nil: done = await run()
                case "too_early": error = "Not yet."
                case "gone": error = "This waited too long. Start again."
                case "relay": error = "The relay isn't answering, and sealctl can't finish until it confirms nothing was cancelled."
                case let r?:
                    let by = String(r.dropFirst("cancelled:".count))
                    error = "Cancelled from \(e.machine(by).map(e.displayName) ?? "another device"). Nothing happened."
                }
                return
            }
            do {
                if try await e.startPhoneAction(what) == nil { done = await run() }
            } catch {
                self.error = Texts.relayDown
            }
        }
    }
}

/// Show words is level 3 (11.18): it then shows the 24 words in the protected view and tells
/// every machine it did.
struct ShowWordsView: View {
    @Environment(AppModel.self) private var model
    @Environment(Router.self) private var router
    @SwiftUI.State private var error: String?

    var body: some View {
        let e = model.engine!
        if let list = e.words.shown {
            Page("Your words", onBack: { e.words.release(); router.pop() }) {
                Protected {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(0..<list.count, id: \.self) { i in WordRow(number: i + 1, word: list[i]) }
                    }
                }
                MutedText("Correct your card, then check again.")
            }
            .onDisappear { e.words.release() }
        } else {
            PhoneAction(what: "words", reason: "Confirm showing your words.", button: Texts.confirm(e.biometryName)) {
                TitleText("Show your words")
                BodyText("Showing the words is a sensitive action. Every paired computer is told.")
                ErrorText(error)
            } run: {
                if await e.words.show() == .passed {
                    Task { await e.sendNotice(what: "words", state: "done", machine: nil, delayId: nil, at: nil) }
                } else {
                    error = "The words weren't opened."
                }
                return nil
            }
        }
    }
}

struct DeleteRelayView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let e = model.engine!
        let n = e.liveMachines.count
        PhoneAction(what: "delete", reason: "Confirm deleting your relay data.", button: "Delete") {
            TitleText("Delete your data on the relay?")
            BodyText("This unpairs your \(n) machines and deletes what the relay keeps for these words: your encrypted phone backup, your machines' records and every phone's notification address. It can't be undone. The privacy policy lists what stays.")
            BodyText("Your words, what this phone keeps, and your sealed files are not touched. To use a machine again, run `sealctl pair` on it.")
        } run: {
            await e.deleteRelayData(lockFirst: true).text
        }
    }
}

/// Erase sealctl from this phone (11.19): Face ID or the passcode first.
struct EraseView: View {
    @Environment(AppModel.self) private var model
    @Environment(Router.self) private var router
    @SwiftUI.State private var alsoBackup = false

    var body: some View {
        let e = model.engine!
        Page(onBack: { router.pop() }) {
            Gap(24)
            TitleText("Remove sealctl from this phone?")
            BodyText("This removes your words, machines, places and history from this phone. Your machines stay paired; your card restores everything on any phone.")
            Toggle(isOn: $alsoBackup) {
                Text("Also remove the copy in iCloud Keychain").foregroundStyle(Palette.ink)
            }
            .tint(Palette.accent)
            .accessibilityIdentifier("Also remove the copy in iCloud Keychain")
        } bottom: {
            SecondaryButton("Delete my relay data first") {
                router.pop()
                router.push(.deleteRelay)
            }
            PrimaryButton("Erase") {
                Task {
                    guard await e.vault.authenticateOwner(reason: "Remove sealctl from this phone.") == .passed else { return }
                    router.reset()
                    await e.erase(alsoBackup: alsoBackup)
                }
            }
            PlainButton("Cancel") { router.pop() }
        }
    }
}
