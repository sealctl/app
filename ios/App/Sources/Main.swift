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

struct MachineRow: View {
    @Environment(Router.self) private var router
    let v: MachineView
    let now: Int64

    var body: some View {
        Button { router.push(.machineDetail(v.machine.key)) } label: {
            SurfaceCard {
                HStack(alignment: .firstTextBaseline) {
                    if v.machine.nickname != nil {
                        Text(v.name).fontWeight(.semibold).foregroundStyle(Palette.ink)
                    } else {
                        MonoText(v.name, weight: .semibold)
                    }
                    Spacer()
                    StateLabel(v.state.kind, v.row, spoken: v.spoken)
                }
                let sub = [v.machine.nickname != nil ? shown(v.machine.name) : nil, v.machine.model.map { shown($0) },
                           "seen \(Texts.ago(v.machine.lastSeen.map { Int64($0) }, now: now))"].compactMap { $0 }
                Text(sub.joined(separator: " · ")).font(.subheadline).foregroundStyle(Palette.muted)
                if v.machine.flagged {
                    Text("Not seen for \((now - Int64(v.machine.lastSeen ?? 0)) / 86_400_000) days").font(.subheadline)
                        .foregroundStyle(Palette.waiting)
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(v.name), \(v.spoken)")
        .accessibilityIdentifier("machine \(v.machine.name)")
    }
}

// MARK: Activity (11.12)

struct ActivityList: View {
    @Environment(AppModel.self) private var model
    @Environment(Router.self) private var router
    let machine: String?
    @SwiftUI.State private var entries: [UsageEntry] = []
    @SwiftUI.State private var showMonths = false

    var body: some View {
        let e = model.engine!
        let month = String(Texts.isoDate(nowMs()).prefix(7))
        let summaries = e.state.summaries.sorted { $0.month > $1.month }
        let current = summaries.first { $0.month == month }
        Group {
            SurfaceCard {
                summary(month, current)
                if summaries.contains(where: { $0.month != month }) {
                    Button { showMonths.toggle() } label: {
                        Image(systemName: showMonths ? "chevron.up" : "chevron.down").frame(maxWidth: .infinity, minHeight: 32)
                    }
                    .accessibilityLabel("Previous months")
                }
                if showMonths {
                    ForEach(summaries.filter { $0.month != month }, id: \.month) { s in summary(s.month, s) }
                }
            }
            ForEach(e.state.reports.sorted { $0.time > $1.time }.prefix(5), id: \.id) { r in
                Button { router.push(.report(r.id)) } label: {
                    SurfaceCard {
                        Text(verbatim: r.what == "leave" ? "This phone left sealctl" : "\(shown(r.machineName)) handed everything back")
                            .fontWeight(.semibold).foregroundStyle(Palette.ink)
                        MutedText("\(r.items.filter { $0.state == "done" }.count) of \(r.items.count) done · \(Texts.mediumDate(Int64(r.time)))")
                    }
                }
                .buttonStyle(.plain)
            }
            if entries.isEmpty {
                MutedText("Nothing yet. Every use of your keys shows here.")
            } else {
                let days = Dictionary(grouping: entries) { Texts.mediumDate(Int64($0.time)) }
                let order = entries.map { Texts.mediumDate(Int64($0.time)) }.reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
                ForEach(order, id: \.self) { day in
                    SectionLabel(day)
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(Array((days[day] ?? []).enumerated()), id: \.offset) { _, u in
                            ActivityLine(time: Texts.time(Int64(u.time)), row: activityRow(entry: u, machine: e.machine(u.machine)))
                        }
                    }
                }
            }
        }
        .task(id: e.state) { entries = await e.usage(machine: machine) }
    }

    private func summary(_ month: String, _ s: MonthSummary?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(monthName(month)).font(.headline).foregroundStyle(Palette.ink)
            Text("\(s?.keysUsed ?? 0) keys used on \(s?.machines.count ?? 0) machines").foregroundStyle(Palette.ink2)
            Text("\(s?.requestsDeclined ?? 0) requests declined").foregroundStyle(Palette.ink2)
            MutedText("No key was written to disk.")
        }
    }

    private func monthName(_ ym: String) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM"
        guard let d = f.date(from: ym) else { return ym }
        f.setLocalizedDateFormatFromTemplate("MMMM")
        return f.string(from: d)
    }
}

/// One use (11.12): the time, what was used and the outcome, then the details in muted text.
struct ActivityLine: View {
    let time: String
    let row: ActivityRow
    @ScaledMetric(relativeTo: .subheadline) private var timeWidth: CGFloat = 52

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            Text(verbatim: time).font(.subheadline).monospacedDigit().foregroundStyle(Palette.ink2)
                .frame(width: timeWidth, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(verbatim: row.subject).foregroundStyle(Palette.ink)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text(verbatim: row.outcome).font(.subheadline).foregroundStyle(tone)
                }
                if !row.details.isEmpty {
                    Text(verbatim: Texts.activityDetails(row)).font(.footnote).foregroundStyle(Palette.muted)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: Texts.activityLabel(time, row)))
    }

    private var tone: Color {
        switch row.tone {
        case .declined: Palette.accent
        case .muted: Palette.muted
        case .normal: Palette.ink2
        }
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
