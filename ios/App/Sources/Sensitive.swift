import DesignSystem
import Engine
import EngineKit
import SealCore
import SwiftUI
import UIKit
import Vault

private enum SStep { case number, wrongNumber, plan, cardWords, done, delay }

/// Levels 2 and 3 (SPEC.md 11.23): full screen, never a sheet, never from a notification
/// button. Number match, the plan or objects, biometrics, the delay, the report.
struct SensitiveView: View {
    @Environment(AppModel.self) private var model
    @Environment(Router.self) private var router
    let requestId: String
    @SwiftUI.State private var step: SStep?
    @SwiftUI.State private var error: String?
    @SwiftUI.State private var cardChecked = false
    /// The card asked before a new gate (`changed` or `noGate`); then the prompt makes it.
    @SwiftUI.State private var gateWhy: GateResult?
    @SwiftUI.State private var name = ""
    @SwiftUI.State private var machineKey = ""

    var body: some View {
        let e = model.engine!
        let w = e.waiting.first { $0.id == requestId }
        let current = step ?? (w?.verdict.needsNumber == true ? .number : .plan)
        Group {
            if w == nil && current != .delay && current != .done && current != .wrongNumber {
                Page(onBack: { router.pop() }) {
                    Gap(24)
                    TitleText(Texts.stoppedWaiting(name.isEmpty ? "The machine" : name))
                } bottom: { SecondaryButton("Close") { router.pop() } }
            } else {
                switch current {
                case .number: NumberMatchView(w: w!, name: name, onPick: { ok in
                    if ok { step = .plan } else { Task { await e.wrongNumber(w!); step = .wrongNumber } }
                }, onNone: { deny(w, e) })
                case .wrongNumber:
                    Page(onBack: { router.pop() }) {
                        Gap(24)
                        TitleText(Texts.wrongNumber(name))
                        BodyText(Texts.wrongNumberBody)
                        MutedText(Texts.wrongNumberWhat)
                    } bottom: {
                        SecondaryButton("What to do") {
                            router.pop()
                            router.push(.lostMachine(machineKey))
                        }
                        PrimaryButton("Close") { router.pop() }
                    }
                case .plan: PlanView(w: w!, name: name, error: error, onConfirm: { confirm(w!, e) }, onDeny: { deny(w, e) })
                case .cardWords:
                    if let why = gateWhy {
                        GateCardWordsView(why: why, onPassed: {
                            gateWhy = nil
                            step = .plan
                            if let w { confirm(w, e) }
                        }, onCancel: { gateWhy = nil; step = .plan })
                    } else {
                        CardWordsView(positions: 2, groups: 2, title: "Use your card", body: nil, onPassed: {
                            cardChecked = true
                            Task {
                                if w?.verdict.needsBiometrics == true { await e.vault.resetGate() }
                                step = .plan
                            }
                        }, onCancel: { step = .plan })
                    }
                case .delay: DelayView(id: requestId, title: Texts.leaving(name))
                case .done:
                    Page(onBack: { router.pop() }) {
                        Gap(24)
                        TitleText("Confirmed")
                        BodyText("\(name) goes ahead now. Its report shows here when it is done.", markdown: false)
                    } bottom: { PrimaryButton("Done") { router.pop() } }
                }
            }
        }
        .onAppear {
            // The name stays after the request leaves the waiting list (answered, refused).
            if let w, name.isEmpty {
                name = e.displayName(w.machine)
                machineKey = w.machine.key
            }
        }
    }

    private func deny(_ w: Waiting?, _ e: AppEngine) {
        Task {
            if let w { await e.deny(w) }
            haptic(false)
            router.pop()
        }
    }

    private func confirm(_ w: Waiting, _ e: AppEngine) {
        Task {
            let level3 = w.verdict.level >= 3
            if w.verdict.needsCardWords && !cardChecked {
                step = .cardWords
                return
            }
            if w.verdict.needsBiometrics && !cardChecked {
                let result = await e.vault.gate(reason: "Confirm handing back \(name).")
                switch result {
                case .passed: break
                case .cancelled: return
                case .lockedOut:
                    if level3 {
                        await e.refuse(w, .noBiometrics)
                        error = Texts.lockedOut(e.biometryName)
                        return
                    }
                    step = .cardWords
                    return
                case .unavailable:
                    if level3 {
                        await e.refuse(w, .noBiometrics)
                        error = Texts.noBiometrics(e.biometryName)
                        return
                    }
                    step = .cardWords
                    return
                case .changed, .noGate:
                    // Two card words, then this prompt again makes the new gate (9.6).
                    gateWhy = result
                    step = .cardWords
                    return
                case .failed(let m):
                    error = "Couldn't confirm (\(m))."
                    return
                }
            }
            let ok = await e.confirmSensitive(w)
            if !ok {
                // Still waiting: the reply did not go and can be confirmed again.
                let still = e.waiting.contains { $0.id == w.id && !$0.expired }
                error = still ? Texts.answerNotSent : Texts.stoppedWaiting(name)
                return
            }
            haptic(true)
            // The confirm decides the delay (9.6): it recorded one when the approval waits.
            step = w.verdict.kind == .unseal && e.local.delayed.contains { $0.id == w.id } ? .delay : .done
        }
    }
}

/// "Which number does dev@mbp.example.com show?" Nothing on this screen comes from the machine.
private struct NumberMatchView: View {
    let w: Waiting
    let name: String
    let onPick: (Bool) -> Void
    let onNone: () -> Void
    @SwiftUI.State private var choices: [UInt32] = []

    var body: some View {
        Page(onBack: nil) {
            Gap(24)
            TitleText(Texts.whichNumber(name))
            BodyText(Texts.lookAtTerminal)
            HStack(spacing: 12) {
                ForEach(choices, id: \.self) { n in
                    Button { onPick(w.request.checkMatch(pick: n)) } label: {
                        Text(verbatim: "\(n)").font(.system(size: 34, weight: .semibold, design: .monospaced))
                            .foregroundStyle(Palette.ink)
                            .frame(maxWidth: .infinity, minHeight: 76)
                            .background(Palette.surface, in: RoundedRectangle(cornerRadius: 12))
                            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Palette.border, lineWidth: 1.5))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Number \(n)")
                    .accessibilityIdentifier("number \(n)")
                }
            }
        } bottom: {
            PlainButton(Texts.noNumber, action: onNone)
        }
        .onAppear { if choices.isEmpty { choices = w.request.matchChoices() } }
    }
}

/// The plan or object list, the delay line and [Confirm with Face ID].
private struct PlanView: View {
    @Environment(AppModel.self) private var model
    let w: Waiting
    let name: String
    let error: String?
    let onConfirm: () -> Void
    let onDeny: () -> Void

    var body: some View {
        let e = model.engine!
        let level3 = w.verdict.level >= 3
        Page(onBack: nil) {
            Gap(12)
            switch w.verdict.kind {
            case .unseal:
                let plan = w.plan
                let all = plan?.all == true || level3
                let first = plan?.items.first { $0.kind != "pairing" }
                TitleText(all ? Texts.handBackAll(name) : "Hand back \(shown(first?.kind ?? "", Texts.maxAgent)) \(shown(first?.name ?? "")) from \(name)?")
                if all { BodyText(Texts.handBackAllBody) }
                ForEach(Array((plan?.items ?? []).enumerated()), id: \.offset) { i, it in
                    HStack(alignment: .firstTextBaseline) {
                        Text(verbatim: "\(i + 1)").font(Fonts.mono(.subheadline)).foregroundStyle(Palette.muted).frame(width: 28, alignment: .leading)
                        MonoText("\(planLabel(shown(it.kind, Texts.maxAgent))) · \(shown(it.name))")
                    }
                    .accessibilityElement(children: .combine)
                }
            case .keys:
                let s = w.request.ctx()?.subject
                TitleText("Let sealctl seal take over \(shown(s?.kind ?? "", Texts.maxAgent)) \(shown(s?.name ?? "")) on \(name)?")
                ForEach(Array(w.request.items().enumerated()), id: \.offset) { _, i in
                    MonoText("\(shown(i.purpose, Texts.maxAgent)) · \(shown(i.object?.path ?? i.id, Texts.maxLine))")
                }
            case .rewrap:
                TitleText("Move \(name) to new words?")
                BodyText("\(w.request.items().count) objects. Each takes seconds.")
            default:
                TitleText(Texts.title(Texts.facts(w, machineName: name)))
            }
            if level3 {
                Gap(4)
                // The rule the confirm applies (9.6), from the place the phone is in now.
                let delayed = AppEngine.confirmDelay(arrival: Int(w.verdict.delaySecs), level: Int(w.verdict.level),
                                                     liftedNow: e.delayLifted()) > 0
                if !delayed {
                    BodyText("At \(e.currentPlaceName ?? "your trusted place"): \(Texts.atTrusted)")
                } else if e.placeKind() == .other {
                    BodyText(Texts.away)
                } else {
                    BodyText(Texts.awayNoLocation)
                }
            }
            if w.verdict.needsCardWords {
                MutedText("This phone has no \(e.biometryName) set up: two words from your card confirm it instead.")
            }
        } bottom: {
            ErrorText(error)
            PrimaryButton(Texts.confirm(e.biometryName), action: onConfirm)
            PlainButton("Deny", action: onDeny)
        }
    }
}

/// What the delay screen of an action this install started on the phone does once its wait is
/// over (11.23): `onReady` (Show my words, Finish) until it expires, then `onStartAgain`.
/// `busy` while one of them runs, so a second tap starts nothing.
struct PhoneActionButtons {
    let what: String
    let busy: Bool
    let error: String?
    let onReady: () -> Void
    let onStartAgain: () -> Void
}

/// A delayed approval (11.23 Delay): its countdown with Cancel. For an action this install
/// started on the phone (`phone`), the screen turns ready by itself at `releaseAt`, notification
/// or not: "Ready until …" with `onReady`; after `expires`, "This waited too long" with Start again.
struct DelayView: View {
    @Environment(AppModel.self) private var model
    @Environment(Router.self) private var router
    let id: String
    let title: String
    var phone: PhoneActionButtons?

    var body: some View {
        let e = model.engine!
        let d = e.local.delayed.first { $0.id == id }
        Ticker { now in
            let phase = d.map { delayPhase(action: $0, now: UInt64(clamping: now)) }
            Page(onBack: { router.pop() }) {
                Gap(24)
                TitleText(title)
                if let d {
                    switch phase {
                    case .waiting:
                        if phone != nil {
                            Text(Texts.minutesLeft(Int64(d.releaseAt), now: now)).font(.title3.weight(.semibold)).foregroundStyle(Palette.waiting)
                                .accessibilityIdentifier("countdown")
                            MutedText(Texts.goesAheadAt(started: Int64(d.started), at: Int64(d.releaseAt)))
                        } else {
                            Text(Texts.startsAt(Int64(d.releaseAt), now: now)).font(.title3.weight(.semibold)).foregroundStyle(Palette.waiting)
                                .accessibilityIdentifier("countdown")
                        }
                        BodyText(Texts.delayWaiting(d.what, at: Int64(d.releaseAt)))
                    case .ready:
                        if phone != nil {
                            Text(Texts.readyUntil(Int64(d.expires))).font(.title3.weight(.semibold)).foregroundStyle(Palette.accent)
                                .accessibilityIdentifier("ready")
                            BodyText(Texts.readyBody)
                        } else {
                            BodyText(Texts.delayOver(d.what))
                        }
                    case .cancelled:
                        if d.cancelledBy == nil || d.cancelledBy == "phone" {
                            BodyText(Texts.delayCancelledHere(d.what))
                        } else {
                            BodyText(Texts.cancelledFrom(d.cancelledBy.flatMap { e.machine($0) }.map(e.displayName) ?? "a computer"))
                        }
                    case .finished:
                        BodyText(Texts.delayOver(d.what))
                    default:
                        BodyText(Texts.delayGone(d.what))
                    }
                } else {
                    BodyText(Texts.delayGone(nil))
                }
            } bottom: {
                ErrorText(phone?.error)
                if phase == .waiting {
                    PrimaryButton("Cancel") { Task { await e.cancelDelayed(id) } }
                } else if phase == .ready, let phone {
                    PrimaryButton(Texts.readyButton(phone.what), enabled: !phone.busy) { phone.onReady() }
                    PlainButton("Cancel") { Task { await e.cancelDelayed(id) } }
                } else if phase == .expired, let phone {
                    PrimaryButton(Texts.startAgain, enabled: !phone.busy) { phone.onStartAgain() }
                    PlainButton("Close") { router.pop() }
                } else {
                    PrimaryButton("Close") { router.pop() }
                }
            }
        }
        .task(id: id) {
            while !Task.isCancelled {
                await e.refreshDelayed()
                try? await Task.sleep(for: .seconds(15))
            }
        }
    }
}

/// A delayed record's screen, from a notification or a banner. An action this install started
/// on the phone opens its own screen, which can finish it once ready (11.23).
struct DelayedView: View {
    @Environment(AppModel.self) private var model
    let id: String

    var body: some View {
        let e = model.engine!
        let d = e.local.delayed.first { $0.id == id }
        let own = d.map { $0.machine == nil } ?? false
        if own, d?.what == "words" {
            ShowWordsView(focus: id)
        } else if own, d?.what == "delete" {
            DeleteRelayView(focus: id)
        } else if own, d?.what == "leave", e.local.leaveStep == 3 {
            LeaveView()
        } else {
            DelayView(id: id, title: Texts.delayScreenTitle(d?.what, name: d?.machine.flatMap { e.machine($0) }.map(e.displayName)))
        }
    }
}

/// The hand-back report (11.23 Report).
struct ReportView: View {
    @Environment(AppModel.self) private var model
    @Environment(Router.self) private var router
    let id: String

    var body: some View {
        let r = model.engine!.state.reports.first { $0.id == id }
        Page(onBack: { router.pop() }) {
            if let r {
                TitleText(r.what == "leave" ? "This phone left sealctl" : "\(shown(r.machineName)) handed everything back")
                let done = r.items.filter { $0.state == "done" }.count
                MutedText("\(done) of \(r.items.count) done · \(Texts.time(Int64(r.time)))")
                ForEach(Array(r.items.enumerated()), id: \.offset) { _, i in
                    let color = i.state == "failed" ? Palette.waiting : i.state == "skipped" ? Palette.muted : Palette.ink
                    MonoText("\(planLabel(shown(i.kind, Texts.maxAgent))) · \(shown(i.name)) → \(shown(i.to, Texts.maxLine))", style: .subheadline, color: color)
                    if i.state == "failed" {
                        Text("Run `sealctl unseal --resume` on that computer.").font(.footnote).foregroundStyle(Palette.waiting)
                    }
                }
                if !r.run.isEmpty {
                    BodyText("Run folder on that computer:")
                    MonoText(shown(r.run, Texts.maxLine), style: .footnote)
                }
                BodyText("Your other computers were told.")
            } else {
                TitleText("Report")
                MutedText("This report is not on this phone.")
            }
        } bottom: {
            PrimaryButton("Done") { router.pop() }
        }
    }
}

extension Texts {
    static let biometryChanged = "A face or fingerprint was added or removed on this phone. Type two words from your card first."
    /// Before the first gate (9.6).
    static func firstGate(_ biometry: String) -> String {
        "Before \(biometry) can confirm sensitive actions on this phone, type two words from your card."
    }
}

/// A card check before a new gate, and what to do once it passed.
struct GateCard {
    let why: GateResult
    let then: () -> Void
}

/// Two words from the card before a new gate (SPEC.md 9.6): the first gate on this phone, or a
/// new one after a face or fingerprint was added or removed. Passing it lets the next prompt
/// make the gate; `onPassed` then asks it again.
struct GateCardWordsView: View {
    @Environment(AppModel.self) private var model
    let why: GateResult
    let onPassed: () -> Void
    let onCancel: () -> Void

    var body: some View {
        let e = model.engine!
        CardWordsView(positions: 2, groups: 2, title: "Use your card",
                      body: why == .noGate ? Texts.firstGate(e.biometryName) : Texts.biometryChanged, onPassed: {
            Task {
                await e.vault.resetGate()
                onPassed()
            }
        }, onCancel: onCancel)
    }
}

/// Typed words from the card (level 2 fallback, Leave sealctl). The words are opened behind
/// Face ID or the passcode and checked inside the core; nothing typed is kept.
struct CardWordsView: View {
    @Environment(AppModel.self) private var model
    let positions: Int
    let groups: Int
    let title: String
    let body_: String?
    /// Leave sealctl's card check names the wrong word (11.23). Where the card stands in for
    /// biometrics, a wrong check says only that the words don't match, so each word can't be
    /// guessed on its own.
    let namesWrongWord: Bool
    let onPassed: () -> Void
    let onCancel: () -> Void
    @SwiftUI.State private var opened = false
    @SwiftUI.State private var pos: [Int] = []
    @SwiftUI.State private var typed: [String] = []
    @SwiftUI.State private var focus = 0
    @SwiftUI.State private var prefix = ""
    @SwiftUI.State private var message: String?

    init(positions: Int, groups: Int, title: String, body: String?, namesWrongWord: Bool = false,
         onPassed: @escaping () -> Void, onCancel: @escaping () -> Void) {
        self.positions = positions; self.groups = groups; self.title = title; self.body_ = body
        self.namesWrongWord = namesWrongWord
        self.onPassed = onPassed; self.onCancel = onCancel
    }

    private var intro: String {
        body_ ?? "Have your card ready. Type \(positions == 2 ? "two" : "three") words from it."
    }

    var body: some View {
        let words = model.engine!.words
        Group {
            if !opened {
                Page(onBack: onCancel) {
                    Gap(24)
                    TitleText(title)
                    BodyText(intro)
                } bottom: {
                    ErrorText(message)
                    PrimaryButton("Use my card") {
                        Task {
                            switch await words.unlockForCheck() {
                            case .passed:
                                pos = words.positions(count: positions, groups: groups)
                                typed = Array(repeating: "", count: positions)
                                opened = true
                            case .cancelled: break
                            case .failed(let m): message = "Couldn't open the words (\(m))."
                            }
                        }
                    }
                }
            } else {
                Page(onBack: { words.release(); onCancel() }) {
                    TitleText(title)
                    BodyText(intro)
                    ForEach(Array(pos.enumerated()), id: \.offset) { i, p in
                        WordField(number: p, value: typed[i], focused: focus == i, error: false) {
                            focus = i
                            prefix = String(typed[i].prefix(4))
                        }
                    }
                } bottom: {
                    ErrorText(message)
                    WordKeypad(prefix: prefix, onChange: { p in
                        prefix = p
                        typed[focus] = p
                    }, onWord: { w in
                        typed[focus] = w
                        prefix = ""
                        if focus < positions - 1 { focus += 1 }
                    })
                    PrimaryButton("Check", enabled: typed.allSatisfy { !$0.isEmpty }) {
                        if let wrong = pos.indices.first(where: { !words.matches(pos[$0], typed[$0]) }) {
                            message = namesWrongWord ? "That's not word \(pos[wrong]) on these words."
                                : "These aren't the words on your card. Look at your card again."
                        } else {
                            words.release()
                            onPassed()
                        }
                    }
                }
                .secureScreen()
            }
        }
    }
}
