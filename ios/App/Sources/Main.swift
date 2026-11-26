import DesignSystem
import Engine
import EngineKit
import SealCore
import SwiftUI
import UIKit

/// The main tabs and the screens pushed over them (SPEC.md 6.2, 11.2).
struct MainView: View {
    @Environment(AppModel.self) private var model
    @Environment(Router.self) private var router

    var body: some View {
        @Bindable var router = router
        let e = model.engine!
        let oneTap = e.waiting.filter { $0.verdict.asking == .oneTap }
        ZStack(alignment: .bottom) {
            Group {
                if let top = router.top {
                    screen(top).id(top)
                } else {
                    tabs
                }
            }
            if let t = e.toast {
                Text(t.text).font(.subheadline.weight(.medium)).foregroundStyle(Palette.ink)
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .background(Palette.surface2, in: Capsule())
                    .padding(.bottom, 90)
                    .accessibilityIdentifier("toast")
                    .task(id: t.id) {
                        try? await Task.sleep(for: .seconds(1.5))
                        if e.toast?.id == t.id { e.toast = nil }
                    }
            }
        }
        // The approval card: a sheet over any screen (11.7); never over levels 2 and 3.
        .sheet(isPresented: Binding(get: { !oneTap.isEmpty && !isSensitive(router.top) }, set: { _ in })) {
            ApprovalSheet()
                .environment(model)
                .environment(router)
                .presentationDetents([.large])
                .interactiveDismissDisabled()
        }
        // Sensitive requests open full screen as soon as they arrive in the foreground.
        .onChange(of: e.waiting.map(\.id)) { _, _ in openSensitive(e) }
        .onAppear { openSensitive(e) }
    }

    private func isSensitive(_ r: Route?) -> Bool {
        if case .sensitive = r { return true }
        return false
    }

    private func openSensitive(_ e: AppEngine) {
        guard let w = e.waiting.first(where: { $0.verdict.asking == .inApp && !$0.expired }) else { return }
        if router.stack.contains(.sensitive(w.id)) { return }
        router.stack.removeAll { isSensitive($0) }
        router.push(.sensitive(w.id))
    }

    private var tabs: some View {
        @Bindable var router = router
        return TabView(selection: $router.tab) {
            MachinesTab().tabItem { Label("Machines", systemImage: "desktopcomputer") }.tag(Tab.machines)
            Page("Activity", onBack: nil) { ActivityList(machine: nil) }
                .tabItem { Label("Activity", systemImage: "list.bullet") }.tag(Tab.activity)
            Page("Inventory", onBack: nil) { InventoryList(machine: nil) }
                .tabItem { Label("Inventory", systemImage: "key") }.tag(Tab.inventory)
            SettingsTab().tabItem { Label("Settings", systemImage: "gearshape") }.tag(Tab.settings)
        }
    }

    @ViewBuilder
    private func screen(_ r: Route) -> some View {
        switch r {
        case .machineDetail(let k): MachineDetailView(key: k)
        case .lostMachine(let k): LostMachineView(key: k)
        case .pair(let fromLink): PairingView(fromLink: fromLink)
        case .answers: AnswersView()
        case .places: PlacesView()
        case .devices: DevicesView()
        case .about: AboutView()
        case .licences: LicencesView()
        case .showWords: ShowWordsView()
        case .deleteRelay: DeleteRelayView()
        case .erase: EraseView()
        case .leave: LeaveView()
        case .report(let id): ReportView(id: id)
        case .delayed(let id): DelayedView(id: id)
        case .sensitive(let id): SensitiveView(requestId: id)
        case .activity(let m): Page("Activity", onBack: { router.pop() }) { ActivityList(machine: m) }
        case .inventory(let m): Page("Inventory", onBack: { router.pop() }) { InventoryList(machine: m) }
        }
    }
}

// MARK: Machines (11.8, 11.17)

struct MachinesTab: View {
    @Environment(AppModel.self) private var model
    @Environment(Router.self) private var router

    var body: some View {
        let e = model.engine!
        Ticker { now in
            let views = MachineView.sorted(e.liveMachines.map { MachineView.of($0, e, now: now) })
            Page("Machines", onBack: nil) {
                banners(e, now: now)
                if views.isEmpty {
                    Gap(24)
                    MutedText("No machines yet. On your computer, run `sealctl pair` and scan the code.")
                    PrimaryButton("Scan code") { router.push(.pair(fromLink: false)) }
                } else {
                    ForEach(views) { v in MachineRow(v: v, now: now) }
                    HStack(spacing: 8) {
                        SecondaryButton("Pair a machine") { router.push(.pair(fromLink: false)) }
                        SecondaryButton("Lock all") {
                            Task {
                                let n = await e.lockAll()
                                e.show("Locked \(n) machines.")
                            }
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func banners(_ e: AppEngine, now: Int64) -> some View {
        let b = e.banners
        if b.offline {
            Banner(Texts.offline)
        } else if b.relayDown {
            Banner(Texts.relayDown)
        }
        if b.rateLimitedUntil > now { Banner(Texts.rateLimited(b.rateLimitedUntil)) }
        if b.clockSkew {
            Banner(Texts.clock) { TextButton("Open settings") { Links.settings() } }
        }
        if b.signatureRefused { Banner(Texts.signature) }
        if !e.notificationsAllowed {
            Banner(Texts.notificationsOff) { TextButton("Open settings") { Links.notificationSettings() } }
        }
        if e.placesNeedAlways {
            Banner(Texts.placesAlways) { TextButton("Open settings") { Links.settings() } }
        }
        let change = e.local.delayed.filter { $0.state == "waiting" && Int64($0.releaseAt) > now }
        ForEach(change, id: \.id) { d in
            let name = d.machine.flatMap { e.machine($0) }.map(e.displayName) ?? "This phone"
            Banner(Texts.delayedAt(d.what, name: name, at: Int64(d.releaseAt)), tone: Palette.accentSoft) {
                HStack(spacing: 16) {
                    TextButton("Show") { router.push(.delayed(d.id)) }
                    TextButton("Cancel") { Task { await e.cancelDelayed(d.id) } }
                }
            }
        }
        let live = e.waiting.filter { !$0.expired }
        if !live.isEmpty {
            Banner("\(live.count) waiting on this phone", tone: Palette.accentSoft) {
                TextButton("Show") {
                    let w = live[0]
                    if w.verdict.asking == .inApp { router.push(.sensitive(w.id)) } else { e.focusRequest = w.id }
                }
            }
        }
    }
}

/// A machine on the list (11.17): its short name, its state, then the model and when it was seen.
struct MachineRow: View {
    @Environment(Router.self) private var router
    let v: MachineView
    let now: Int64

    var body: some View {
        Button { router.push(.machineDetail(v.machine.key)) } label: {
            SurfaceCard {
                Text(v.name).fontWeight(.semibold).foregroundStyle(Palette.ink).lineLimit(1).truncationMode(.tail)
                StateLabel(v.state.kind, v.row, spoken: v.spoken)
                Text(v.sub(now: now)).font(.subheadline).foregroundStyle(Palette.muted)
                if let unseen = v.unseen(now: now) {
                    Text(unseen).font(.subheadline).foregroundStyle(Palette.waiting)
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(v.label(now: now))
        .accessibilityIdentifier("machine \(v.machine.name)")
    }
}

// MARK: Inventory (11.13)

struct InventoryList: View {
    @Environment(AppModel.self) private var model
    let machine: String?

    var body: some View {
        let e = model.engine!
        let items = e.state.inventory.filter { !$0.deleted && (machine == nil || $0.machine == machine) }
        let current = e.state.words?.fingerprint
        if items.isEmpty {
            MutedText("No keys handed out yet.")
        } else {
            let groups = Dictionary(grouping: items, by: \.machine)
            ForEach(groups.keys.sorted(), id: \.self) { m in
                SectionLabel(e.machine(m).map(e.displayName) ?? String(m.prefix(8)))
                ForEach(groups[m] ?? [], id: \.id) { i in
                    SurfaceCard {
                        HStack(spacing: 4) {
                            Text(purposeName(i.purpose)).fontWeight(.semibold).foregroundStyle(Palette.ink)
                            MonoText("\(i.id.prefix(4))…\(i.id.suffix(2))", style: .subheadline)
                            Text("· seed").foregroundStyle(Palette.ink2)
                            MonoText(i.words, style: .subheadline)
                        }
                        .accessibilityElement(children: .combine)
                        if !i.path.isEmpty {
                            MonoText([shown(i.path, Texts.maxLine), i.size > 0 ? "\(i.size / 1000) KB" : nil].compactMap { $0 }.joined(separator: " · "),
                                     style: .footnote, color: Palette.ink2)
                        }
                        MutedText("First used \(Texts.isoDate(Int64(i.firstUse))) · last used \(Texts.ago(Int64(i.lastUse)))")
                        if i.stale { Text("Not seen since \(Texts.isoDate(Int64(i.lastUse)))").foregroundStyle(Palette.waiting) }
                        if let current, i.words != current { Text("Seed \(i.words) (retired)").foregroundStyle(Palette.muted) }
                    }
                }
            }
        }
    }
}
