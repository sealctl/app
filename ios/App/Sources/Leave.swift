import DesignSystem
import Engine
import EngineKit
import SealCore
import SwiftUI
import UIKit
import Vault

/// Leave sealctl (SPEC.md 11.22). Each step is saved, so a closed app resumes where it left.
/// Steps: 1 what happens, 2 each computer, 3 confirm (+ delay), 4 card check, 5 relay data
/// and words backup, 6 what happened, 7 the card.
struct LeaveView: View {
    @Environment(AppModel.self) private var model
    @Environment(Router.self) private var router
    @SwiftUI.State private var error: String?
    @SwiftUI.State private var running = false
    @SwiftUI.State private var lostCard = false
    /// A face or fingerprint was added or removed at this step (1 or 3): two card words, then a
    /// new gate (9.6), then the step goes on.
    @SwiftUI.State private var cardAt: Int?

    var body: some View {
        let e = model.engine!
        if let at = cardAt {
            CardWordsView(positions: 2, groups: 2, title: "Use your card", body: Texts.biometryChanged, onPassed: {
                Task {
                    await e.vault.resetGate()
                    cardAt = nil
                    if at == 1 { start(e) } else { confirm(e, pendingLeave(e)) }
                }
            }, onCancel: { cardAt = nil })
        } else {
            steps(e)
        }
    }

    @ViewBuilder
    private func steps(_ e: AppEngine) -> some View {
        let step = max(Int(e.local.leaveStep), 1)
        switch step {
        case 1:
            Page(onBack: { cancel(e) }) {
                Gap(24)
                TitleText("Unseal all machines and leave")
                BodyText("sealctl hands everything back to you before you go. On each computer, `sealctl unseal --all` moves your volumes, backups, SSH keys and secrets to passwords of your own. Your files stay encrypted.")
                BodyText("Then this phone deletes your data on the relay and the copy of your words in iCloud Keychain.")
                ErrorText(error)
            } bottom: {
                PrimaryButton("Start") { start(e) }
                PlainButton("Cancel") { cancel(e) }
            }
        case 2:
            EachComputerView(onContinue: { Task { await go(e, 3) } }, onSkip: { key in
                Task { await go(e, 2, skipped: e.local.leaveSkipped + [key]) }
            }, onBack: { cancel(e) })
        case 3:
            confirmStep(e)
        case 4:
            if lostCard {
                Page(onBack: nil) {
                    Gap(24)
                    BodyText("Keep the copy in iCloud Keychain until you find it, or write a new card first (Show words).")
                } bottom: { PrimaryButton("Close") { cancel(e) } }
            } else {
                CardWordsView(positions: 3, groups: 3, title: "Check your card first",
                              body: "After this, your paper card is the only copy of your words. Type three words from it.",
                              namesWrongWord: true, onPassed: { Task { await go(e, 5) } }, onCancel: { lostCard = true })
            }
        case 5:
            Page(onBack: nil) {
                Gap(24)
                TitleText("Deleting your relay data")
                BodyText("This removes your words from iCloud Keychain, and from your other devices on the same Apple Account.")
            } bottom: {
                ErrorText(error)
                PrimaryButton(error != nil ? "Try again" : "Continue", enabled: !running) {
                    running = true
                    Task {
                        if await e.leaveDeleteEverything() {
                            error = nil
                            await go(e, 6)
                        } else {
                            error = "The relay isn't answering. Try again."
                        }
                        running = false
                    }
                }
            }
        case 6:
            Page(onBack: nil) {
                Gap(24)
                TitleText("What happened")
                ForEach(e.state.reports.filter { $0.what != "leave" }, id: \.id) { r in
                    BodyText("\(r.machineName): handed back · \(r.items.filter { $0.state == "done" }.count) objects")
                }
                ForEach(e.local.leaveSkipped, id: \.self) { k in
                    BodyText("\(e.state.machines.first { $0.key == k }?.name ?? String(k.prefix(8))): skipped")
                }
                BodyText("Relay data deleted.")
                BodyText("Words backup removed.")
            } bottom: {
                PrimaryButton("Next") { Task { await go(e, 7) } }
            }
        default:
            Page(onBack: nil) {
                Gap(24)
                TitleText("Keep your card for now")
                BodyText("Keep your paper card until no old copies of your backups or volumes remain: older disk images, old backup snapshots in another place, or copies of the store. Those still open only with these words. Then destroy it.")
            } bottom: {
                PrimaryButton("Done") {
                    router.goodbye = true
                    Task {
                        await go(e, 0, skipped: [])
                        router.reset()
                        await e.erase(alsoBackup: true)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func confirmStep(_ e: AppEngine) -> some View {
        let pending = pendingLeave(e)
        Ticker { now in
            if let p = pending, Int64(p.releaseAt) > now {
                DelayView(id: p.id, title: "Leaving sealctl")
            } else {
                Page(onBack: { cancel(e) }) {
                    Gap(24)
                    TitleText("Delete your data and the last copy of your words?")
                    BodyText("Next, this phone deletes your data on the relay and removes your words from iCloud Keychain.")
                    if pending != nil {
                        BodyText("The hour is over. Confirm again to finish.")
                    } else if e.delayLifted() {
                        BodyText("At \(e.currentPlaceName ?? "your trusted place"): this happens as soon as you confirm.")
                    } else {
                        BodyText("This starts two hours after you confirm. Your phone and your computers can cancel it until then.")
                    }
                } bottom: {
                    ErrorText(error)
                    PrimaryButton(Texts.confirm(e.biometryName)) { confirm(e, pending) }
                    PlainButton("Cancel") { cancel(e) }
                }
            }
        }
    }

    private func pendingLeave(_ e: AppEngine) -> DelayedAction? {
        e.local.delayed.last { $0.what == "leave" && ($0.state == "waiting" || $0.state == "released") }
    }

    private func start(_ e: AppEngine) {
        Task {
            switch await e.vault.gate(reason: "Confirm leaving sealctl.") {
            case .passed: await go(e, 2)
            case .cancelled: break
            case .lockedOut: error = Texts.lockedOut(e.biometryName)
            case .changed: cardAt = 1
            default: error = Texts.noBiometrics(e.biometryName)
            }
        }
    }

    private func confirm(_ e: AppEngine, _ pending: DelayedAction?) {
        Task {
            switch await e.vault.gate(reason: "Confirm leaving sealctl.") {
            case .passed: break
            case .cancelled: return
            case .lockedOut: error = Texts.lockedOut(e.biometryName); return
            case .changed: cardAt = 3; return
            default: error = Texts.noBiometrics(e.biometryName); return
            }
            if let pending {
                switch await e.finishPhoneAction(pending.id) {
                case nil: await go(e, 4)
                case "relay": error = "The relay isn't answering, and sealctl can't finish until it confirms nothing was cancelled."
                case "gone": error = "This waited too long. Start again."
                case "too_early": error = "Not yet."
                default: error = "Cancelled from another device. Nothing happened."
                }
                return
            }
            do {
                if try await e.startPhoneAction("leave") == nil { await go(e, 4) }
            } catch {
                self.error = Texts.relayDown
            }
        }
    }

    private func go(_ e: AppEngine, _ n: Int, skipped: [String]? = nil) async {
        await e.setLeave(step: n, skipped: skipped ?? e.local.leaveSkipped)
    }

    private func cancel(_ e: AppEngine) {
        Task {
            await e.setLeave(step: 0, skipped: [])
            router.pop()
        }
    }
}

/// Step 2: one row per paired machine, live from the relay's machine list.
private struct EachComputerView: View {
    @Environment(AppModel.self) private var model
    let onContinue: () -> Void
    let onSkip: (String) -> Void
    let onBack: () -> Void
    @SwiftUI.State private var skipping: String?

    var body: some View {
        let e = model.engine!
        let paired = e.relayMachines
        let rows: [(Machine, String, Bool)] = e.state.machines.filter { !$0.deleted }.map { m in
            let handed = paired != nil && !paired!.contains(m.key)
            let skipped = e.local.leaveSkipped.contains(m.key)
            let d = e.local.delayed.last { $0.machine == m.key && $0.state == "waiting" }
            let report = e.state.reports.last { $0.machine == m.key }
            let status: String
            if skipped {
                status = "Skipped"
            } else if handed, let report {
                status = "Handed back · \(report.items.filter { $0.state == "done" }.count) objects"
            } else if handed {
                status = "Handed back"
            } else if let d {
                status = "Starts at \(Texts.time(Int64(d.releaseAt)))"
            } else {
                status = "Waiting for `sealctl unseal --all`"
            }
            return (m, status, handed || skipped)
        }
        Page(onBack: onBack) {
            TitleText("Hand back each computer")
            BodyText("On each computer, run:")
            MonoText("sealctl unseal --all", style: .title3)
            BodyText("It shows a plan and asks before it changes anything. When it asks this phone, tap Allow.")
            ForEach(rows, id: \.0.key) { m, status, _ in
                HStack(alignment: .firstTextBaseline, spacing: 0) {
                    MonoText(m.name, style: .subheadline)
                    Text(LocalizedStringKey(" · \(status)")).font(.subheadline).foregroundStyle(Palette.ink2)
                }
                .accessibilityElement(children: .combine)
            }
            if rows.isEmpty { MutedText("No computers are paired.") }
            if let s = skipping {
                BodyText("Skip \(e.state.machines.first { $0.key == s }?.name ?? "")? Use it when the computer is lost or already wiped. Anything it holds then opens only with your card.")
                HStack(spacing: 20) {
                    TextButton("Skip") { onSkip(s); skipping = nil }
                    TextButton("Cancel") { skipping = nil }
                }
            }
        } bottom: {
            if rows.contains(where: { !$0.2 }) {
                SecondaryButton("Skip a computer") { skipping = rows.first { !$0.2 }?.0.key }
            }
            PrimaryButton("Continue", enabled: rows.allSatisfy(\.2), action: onContinue)
        }
        .task {
            while !Task.isCancelled {
                await e.refreshMachines()
                await e.refreshDelayed()
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }
}
