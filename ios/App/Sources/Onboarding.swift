import DesignSystem
import Engine
import EngineKit
import SealCore
import SwiftUI
import UIKit
import Vault

private enum Step: Hashable {
    case welcome, about, card, ready, words, check, backups, notifications, places, pair
    case restore, restoreConfirm, restoring, oldPhone, changeNow, backupFound, reinstalled
}

/// Onboarding (SPEC.md 11.3) and restore (11.4). The steps can't be skipped; a closed app
/// resumes at the last step not done.
struct OnboardingFlow: View {
    @Environment(AppModel.self) private var model
    let phase: Phase
    @SwiftUI.State private var step: Step?
    @SwiftUI.State private var restoring = false
    @SwiftUI.State private var typed = TypedWords()

    private var start: Step {
        switch phase {
        case .backupFound: return .backupFound
        case .reinstalled: return .reinstalled
        case .cardUnchecked: return .ready
        case .onboarding(let s):
            switch s { case 7: return .backups; case 8: return .notifications; case 9: return .places; default: return .pair }
        default: return .welcome
        }
    }

    var body: some View {
        let current = step ?? start
        Group {
            switch current {
            case .welcome: Welcome(onCreate: { step = .about }, onRestore: { step = .restore })
            case .reinstalled: ReinstalledView()
            case .backupFound:
                BackupFoundView(phase: phase, onRestored: { restoring = true; step = .restoring },
                                onPaper: { step = .restore }, onCreate: { step = .about })
            case .about: AboutWords { step = .card }
            case .card: BlankCard { step = .ready }
            case .ready: GetReady { step = .words }
            case .words: WordsPages { model.engine?.words.hide(); step = .check }
            case .check: CardCheck(onAgain: { step = .ready }, onPassed: { saved in
                backupSaved = saved
                Task { await set(.backups) }
            })
            case .backups: Backups(saved: backupSaved) { Task { await set(.notifications) } }
            case .notifications: NotificationsStep { if restoring { finish() } else { Task { await set(.places) } } }
            case .places: PlacesStep { Task { await set(.pair) } }
            case .pair: PairFirst(onScan: { finish(); model.router.push(.pair(fromLink: false)) }, onLater: { finish() })
            case .restore: RestoreWords(typed: typed, onBack: { typed.clear(); step = .welcome }) { step = .restoreConfirm }
            case .restoreConfirm:
                RestoreConfirm(typed: typed, onNo: { step = .restore }, onYes: { restoring = true; step = .restoring })
            case .restoring: Restoring { step = .oldPhone }
            case .oldPhone: OldPhone(onKept: { Task { await set(.backups) } }, onLost: { step = .changeNow })
            case .changeNow: ChangeNow { Task { await set(.backups) } }
            }
        }
        .onChange(of: phase) { _, p in
            // The card check passed or a restore finished: the persisted step takes over.
            if case .onboarding = p, step == .check || step == .restoring { return }
            if case .ready = p { step = nil }
        }
    }

    @SwiftUI.State private var backupSaved: Bool?

    private func set(_ s: Step) async {
        step = s
        let persisted: UInt32? = switch s {
        case .backups: 7
        case .notifications: 8
        case .places: 9
        case .pair: 10
        default: nil
        }
        if let persisted { await model.engine?.applyLocal(.setOnboardingStep(step: persisted)) }
    }

    private func finish() {
        guard let e = model.engine else { return }
        Task {
            await e.applyLocal(.setOnboardingStep(step: 0))
            await e.computePhase()
            await e.onForeground()
            // The token came before the words: register it now that the phone keys exist.
            await AppDelegate.registerPendingToken(e)
        }
    }
}

// MARK: steps 1 to 10

private struct Welcome: View {
    @Environment(Router.self) private var router
    let onCreate: () -> Void
    let onRestore: () -> Void

    var body: some View {
        Page(onBack: nil) {
            Gap(48)
            if router.goodbye { MutedText("sealctl is gone from this phone. You can delete the app.") }
            Wordmark(size: 34)
            TitleText("Your phone holds the keys.")
            BodyText("When an agent on your computer needs a key, your computer asks this phone. You tap Allow, and the key goes into that one command.")
        } bottom: {
            PrimaryButton("Create new words", action: onCreate)
            SecondaryButton("Restore", action: onRestore)
            HStack(spacing: 4) {
                Text("No account.").foregroundStyle(Palette.muted)
                Button("Privacy") { Links.open("https://sealctl.com/privacy") }
                Text("·").foregroundStyle(Palette.muted)
                Button("Terms") { Links.open("https://sealctl.com/terms") }
            }
            .font(.subheadline)
        }
    }
}

private struct AboutWords: View {
    let onNext: () -> Void
    var body: some View {
        Page(onBack: nil) {
            Gap(32)
            TitleText("24 words open everything")
            BodyText("Every key sealctl hands out comes from 24 words. You write them by hand on a paper card. With the card, you can get everything back on a new phone or open your files with no phone at all.")
            BodyText("The app never shows the words for printing, copying or photos.")
        } bottom: {
            PrimaryButton("Next", action: onNext)
        }
    }
}

private struct BlankCard: View {
    let onDone: () -> Void
    @SwiftUI.State private var letter = ["US", "CA", "MX", "PH", "CL", "CO", "VE"].contains(Locale.current.region?.identifier ?? "")
    @SwiftUI.State private var sharing: URL?

    var body: some View {
        Page(onBack: nil) {
            Gap(32)
            TitleText("Print a blank card")
            BodyText("The card has 24 numbered lines with four boxes each: the first four letters are enough to know each word. It folds to wallet size.")
            HStack(spacing: 8) {
                Text("Paper size:").foregroundStyle(Palette.muted)
                Button("A4") { letter = false }.fontWeight(letter ? .regular : .semibold)
                    .foregroundStyle(letter ? Palette.ink2 : Palette.accent)
                Text("·").foregroundStyle(Palette.muted)
                Button("Letter") { letter = true }.fontWeight(letter ? .semibold : .regular)
                    .foregroundStyle(letter ? Palette.accent : Palette.ink2)
            }
            .frame(minHeight: 44)
            MutedText("No printer? Any paper works. Number 24 lines.")
        } bottom: {
            HStack(spacing: 8) {
                SecondaryButton("Print") { CardPDF.print(letter: letter) }
                ShareLink(item: CardPDF.file(letter: letter)) {
                    Text("Share PDF").font(.body.weight(.medium)).frame(maxWidth: .infinity, minHeight: 48)
                        .foregroundStyle(Palette.ink)
                        .background(Palette.surface, in: RoundedRectangle(cornerRadius: 12))
                        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Palette.border, lineWidth: 1.5))
                }
            }
            PrimaryButton("I have a blank card", action: onDone)
        }
    }
}

private struct GetReady: View {
    @Environment(AppModel.self) private var model
    let onShown: () -> Void
    @SwiftUI.State private var error: String?

    var body: some View {
        Page(onBack: nil) {
            Gap(32)
            TitleText("Write where no camera can see")
            BodyText("Screenshots and screen recordings hide the words. Write each word in full, in the boxes and on the line.")
        } bottom: {
            ErrorText(error)
            PrimaryButton("Show my words") {
                Task {
                    guard let e = model.engine else { return }
                    switch await e.words.create() {
                    case .passed: onShown()
                    case .cancelled: break
                    case .failed(let m): error = "Couldn't open the words (\(m))."
                    }
                }
            }
        }
    }
}

private struct WordsPages: View {
    @Environment(AppModel.self) private var model
    let onDone: () -> Void
    @SwiftUI.State private var page = 0

    var body: some View {
        let words = model.engine?.words.shown ?? []
        Page(onBack: page > 0 ? { page -= 1 } : nil) {
            TitleText("Words \(page * 6 + 1) to \(page * 6 + 6)")
            if words.count == 24 {
                Protected {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(page * 6..<page * 6 + 6, id: \.self) { i in WordRow(number: i + 1, word: words[i]) }
                    }
                }
            }
            if page == 3 {
                Gap(16)
                TitleText("Now fill in the card")
                HStack { Text("Words fingerprint:").foregroundStyle(Palette.ink2); MonoText(model.engine?.words.fingerprintText ?? "", style: .title3, weight: .semibold) }
                    .accessibilityElement(children: .combine)
                HStack { Text("Written on:").foregroundStyle(Palette.ink2); MonoText(Texts.isoDate(nowMs()), style: .title3) }
                    .accessibilityElement(children: .combine)
            }
        } bottom: {
            if page < 3 {
                PrimaryButton("Next") { page += 1 }
            } else {
                PrimaryButton("I've written all 24", action: onDone)
            }
        }
    }
}

/// Step 6: three positions, at least one from each half; four choices each.
private struct CardCheck: View {
    @Environment(AppModel.self) private var model
    let onAgain: () -> Void
    let onPassed: (Bool?) -> Void
    @SwiftUI.State private var positions: [Int] = []
    @SwiftUI.State private var index = 0
    @SwiftUI.State private var wrong = 0
    @SwiftUI.State private var round = 0
    @SwiftUI.State private var message: String?
    @SwiftUI.State private var choices: [String] = []

    var body: some View {
        let words = model.engine?.words
        Page(onBack: nil) {
            if let words, words.hasSession, !positions.isEmpty {
                let pos = positions[index]
                MutedText("Check your card · \(index + 1) of 3")
                TitleText("Which is word \(pos)?")
                ForEach(choices, id: \.self) { c in
                    // The choices are words: drawn in the secure layer, out of screenshots (11.21).
                    ChoiceButton(c, action: { pick(c, pos) }) {
                        SecureWord(text: c, font: Fonts.mono(.title3))
                    }
                }
                ErrorText(message)
            }
        } bottom: {
            if wrong >= 2 { SecondaryButton("Show the words again", action: onAgain) }
        }
        .secureScreen()
        .task {
            guard let words, words.hasSession else { onAgain(); return }
            if positions.isEmpty { positions = words.positions(count: 3, groups: 2) }
            choices = words.choices(positions[index])
        }
        .onChange(of: round) { _, _ in
            if let words, !positions.isEmpty { choices = words.choices(positions[index]) }
        }
    }

    private func pick(_ c: String, _ pos: Int) {
        guard let words = model.engine?.words else { return }
        if words.matches(pos, c) {
            message = nil
            wrong = 0
            if index == 2 {
                Task { onPassed(await words.cardChecked()) }
            } else {
                index += 1
                round += 1
            }
        } else {
            wrong += 1
            round += 1
            message = "That's not word \(pos). Look at your card again."
        }
    }
}

private struct Backups: View {
    @Environment(AppModel.self) private var model
    let saved: Bool?
    let onContinue: () -> Void
    @SwiftUI.State private var retryFailed = false

    var body: some View {
        let e = model.engine
        let settings = e?.state.settings
        Page(onBack: nil) {
            Gap(24)
            TitleText("Backups")
            HStack { Text("Paper card").fontWeight(.semibold).foregroundStyle(Palette.ink); Text("· Written and checked").foregroundStyle(Palette.muted) }
            ToggleRow("iCloud Keychain", isOn: Binding(get: { settings?.keychainBackup ?? true }, set: { on in
                Task { _ = await e?.setKeychainBackup(on) }
            }))
            if saved == false || retryFailed {
                MutedText("Couldn't save to iCloud Keychain. Is iCloud Keychain on in Settings?")
                SecondaryButton("Try again") {
                    Task {
                        // The words are closed after the check: open them again to write the copy.
                        guard let w = e?.words, await w.show() == .passed else { return }
                        w.hide()
                        retryFailed = await w.saveBackup() == false
                        w.release()
                    }
                }
            } else {
                MutedText("A new iPhone on the same Apple Account restores without the words. End-to-end encrypted by Apple.")
            }
            ToggleRow("Encrypted backup on the relay", isOn: Binding(get: { settings?.relayBackup ?? true }, set: { on in
                Task { await e?.setRelayBackup(on) }
            }))
            MutedText("Your machines, places, answers and inventory, encrypted with a key only your words can make. It does not hold your words.")
        } bottom: {
            PrimaryButton("Continue", action: onContinue)
        }
    }
}

private struct NotificationsStep: View {
    @Environment(AppModel.self) private var model
    let onDone: () -> Void
    var body: some View {
        Page(onBack: nil) {
            Gap(32)
            TitleText("Requests arrive as notifications")
            BodyText("When a machine needs a key, this phone shows a notification. You answer with one tap. A locked phone asks for its unlock first.")
        } bottom: {
            PrimaryButton("Allow notifications") {
                Task {
                    _ = await model.notifier.ask()
                    onDone()
                }
            }
            PlainButton("Not now", action: onDone)
        }
    }
}

private struct PlacesStep: View {
    @Environment(AppModel.self) private var model
    let onDone: () -> Void
    var body: some View {
        Page(onBack: nil) {
            Gap(32)
            TitleText("Learn your places?")
            BodyText("sealctl can learn where you work. At a trusted place, reopening your machine needs no tap while your phone is unlocked and near it, and leaving locks the machines you opened there. Locations stay on this phone.")
            MutedText("Without places, a session stays open up to 1 hour and reopening always takes a tap.")
        } bottom: {
            PrimaryButton("Allow location") {
                Task {
                    // When In Use now; Always after the first trusted place (11.9).
                    await model.places.requestWhenInUse()
                    onDone()
                }
            }
            PlainButton("Not now", action: onDone)
        }
    }
}

private struct PairFirst: View {
    let onScan: () -> Void
    let onLater: () -> Void
    var body: some View {
        Page(onBack: nil) {
            Gap(32)
            TitleText("Pair a machine")
            BodyText("On your computer, run:")
            MonoText("sealctl pair", style: .title3)
            BodyText("Then scan the code it shows.")
        } bottom: {
            PrimaryButton("Scan code", action: onScan)
            PlainButton("Later", action: onLater)
        }
    }
}

// MARK: restore (11.4)

/// Keychain items survived a reinstall (7.4).
private struct ReinstalledView: View {
    @Environment(AppModel.self) private var model
    @SwiftUI.State private var fp: String?

    var body: some View {
        Page(onBack: nil) {
            Gap(48)
            Wordmark()
            TitleText("Continue with words \(fp ?? "")")
            BodyText("This iPhone still holds sealctl words from an earlier install.")
        } bottom: {
            PrimaryButton("Continue with words \(fp ?? "")") {
                Task { _ = await model.engine?.continueAfterReinstall() }
            }
            PlainButton("Start over") { Task { await model.engine?.startOverAfterReinstall() } }
        }
        .task {
            if let root = await model.engine?.vault.readRoot() { fp = fingerprint(root: root) }
        }
    }
}

private struct BackupFoundView: View {
    @Environment(AppModel.self) private var model
    let phase: Phase
    let onRestored: () -> Void
    let onPaper: () -> Void
    let onCreate: () -> Void
    @SwiftUI.State private var error: String?
    @SwiftUI.State private var firstSeen = Date()

    var body: some View {
        let (fp, created): (String, Int64) = {
            if case .backupFound(let f, let c) = phase { return (f, c) }
            return ("", 0)
        }()
        Page(onBack: nil) {
            Gap(48)
            Wordmark()
            TitleText("Your words are in iCloud Keychain")
            HStack(spacing: 0) {
                Text("Words ").foregroundStyle(Palette.ink2)
                MonoText(fp)
                Text(", saved on \(Texts.isoDate(created)).").foregroundStyle(Palette.ink2)
            }
            .accessibilityElement(children: .combine)
        } bottom: {
            ErrorText(error)
            PrimaryButton("Restore \(fp)") {
                Task {
                    guard let e = model.engine else { return }
                    guard let bytes = await e.vault.readSyncBackup(), let item = try? backupItemDecode(bytes: bytes) else {
                        error = "The backup can't be read."
                        return
                    }
                    if await e.words.restore(item.words) == .passed {
                        await e.words.restored(item.fingerprint)
                        e.words.release()
                        onRestored()
                    }
                }
            }
            SecondaryButton("Restore from paper", action: onPaper)
            PlainButton("Create new words", action: onCreate)
        }
    }
}

/// Typed words, kept only in this flow's memory.
@MainActor
@Observable
final class TypedWords {
    var words = Array(repeating: "", count: 24)
    var parsed: Words?

    func clear() {
        words = Array(repeating: "", count: 24)
        parsed = nil
    }
}

private struct RestoreWords: View {
    let typed: TypedWords
    let onBack: () -> Void
    let onParsed: () -> Void
    @SwiftUI.State private var focus = 0
    @SwiftUI.State private var prefix = ""
    @SwiftUI.State private var error: String?
    @SwiftUI.State private var bad = -1

    var body: some View {
        Page(onBack: onBack) {
            TitleText("Type your 24 words")
            MutedText("Four letters are enough. Each word completes itself.")
            ForEach(0..<24, id: \.self) { i in
                WordField(number: i + 1, value: typed.words[i], focused: focus == i, error: bad == i) {
                    focus = i
                    prefix = String(typed.words[i].prefix(4))
                }
            }
        } bottom: {
            ErrorText(error)
            WordKeypad(prefix: prefix, onChange: { p in
                prefix = p
                typed.words[focus] = p
            }, onWord: { w in
                typed.words[focus] = w
                prefix = ""
                if focus < 23 { focus += 1 } else { check() }
            })
            if typed.words.allSatisfy({ !$0.isEmpty }) {
                PrimaryButton("Check") { check() }
            }
        }
        .secureScreen()
    }

    private func check() {
        do {
            typed.parsed = try Words.parse(list: typed.words)
            error = nil
            bad = -1
            onParsed()
        } catch CoreError.UnknownWord(let index) {
            bad = Int(index)
            error = "No word starts with '\(typed.words[bad].prefix(4))'."
        } catch {
            self.error = "These words don't fit together. Check the order and spelling against your card."
        }
    }
}

private struct RestoreConfirm: View {
    @Environment(AppModel.self) private var model
    let typed: TypedWords
    let onNo: () -> Void
    let onYes: () -> Void

    var body: some View {
        let fp = typed.parsed.map { fingerprint(root: Root.fromWords(words: $0)) } ?? ""
        Page(onBack: onNo) {
            Gap(32)
            HStack(spacing: 6) {
                TitleText("These are words")
                MonoText(fp, style: .title2, weight: .semibold)
            }
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityElement(children: .combine)
            BodyText("Does your card say \(fp)?")
        } bottom: {
            PrimaryButton("Yes") {
                Task {
                    guard let e = model.engine, let w = typed.parsed else { return }
                    if await e.words.restore(w) == .passed {
                        await e.words.restored(fp)
                        e.words.release()
                        typed.clear()
                        onYes()
                    }
                }
            }
            SecondaryButton("No, check again", action: onNo)
        }
        .task { if typed.parsed == nil { onNo() } }
    }
}

private struct Restoring: View {
    @Environment(AppModel.self) private var model
    let onContinue: () -> Void
    @SwiftUI.State private var loaded = false
    @SwiftUI.State private var empty = false

    var body: some View {
        let s = model.engine?.state
        Page(onBack: nil) {
            Gap(32)
            if !loaded {
                TitleText("Restoring your data")
                ProgressView()
            } else {
                TitleText("Found your backup")
                if empty {
                    BodyText("No relay backup for these words. Your machines will need sealctl pair again, unless they are still paired: they reconnect by themselves.")
                } else if let s {
                    BodyText("\(s.machines.filter { !$0.deleted }.count) machines · \(s.places.filter { !$0.deleted }.count) places · \(s.answers.filter { !$0.deleted }.count) answers · \(s.inventory.filter { !$0.deleted }.count) inventory items")
                }
            }
        } bottom: {
            if loaded { PrimaryButton("Continue", action: onContinue) }
        }
        .task {
            guard let e = model.engine else { return }
            await e.download()
            await e.refreshMachines()
            let st = e.state
            empty = st.machines.allSatisfy(\.deleted) && st.places.isEmpty && st.answers.isEmpty
            loaded = true
            await e.registerPush()
            await AppDelegate.registerPendingToken(e)
        }
    }
}

private struct OldPhone: View {
    let onKept: () -> Void
    let onLost: () -> Void
    var body: some View {
        Page(onBack: nil) {
            Gap(32)
            TitleText("Where is your old phone?")
        } bottom: {
            SecondaryButton("I still have it, or it was reset", action: onKept)
            SecondaryButton("It was lost or stolen", action: onLost)
        }
    }
}

private struct ChangeNow: View {
    let onLater: () -> Void
    @SwiftUI.State private var note: String?
    var body: some View {
        Page(onBack: nil) {
            Gap(32)
            TitleText("Change your words now")
            BodyText("Your old phone holds these words behind its passcode. Changing them makes sure it can't open anything new. It takes about 10 minutes and a new blank card.")
        } bottom: {
            ErrorText(note)
            PrimaryButton("Change words now") { note = "Changing words isn't in this version of the app yet." }
            PlainButton("Remind me tomorrow", action: onLater)
        }
    }
}
