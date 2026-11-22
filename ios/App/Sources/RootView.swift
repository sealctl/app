import DesignSystem
import Engine
import EngineKit
import SwiftUI
import UIKit

/// The app's phase decides the screen (SPEC.md 6.1).
struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(Router.self) private var router
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ZStack {
            Palette.paper.ignoresSafeArea()
            if let e = model.engine {
                content(e)
            } else {
                ProgressView()
            }
            // The app switcher snapshot never shows words (11.21).
            if router.secure > 0 && scenePhase != .active {
                PrivacyCover()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.userDidTakeScreenshotNotification)) { _ in
            if router.secure > 0 { router.screenshotNote = true }
        }
    }

    @ViewBuilder
    private func content(_ e: AppEngine) -> some View {
        switch e.phase {
        case .loading:
            ProgressView()
        case .needsScreenLock:
            NeedsScreenLockView()
        case .wordsLost(let reason):
            WordsLostView(reason: reason)
        case .ready:
            MainView()
        default:
            OnboardingFlow(phase: e.phase)
        }
    }
}

/// A full cover with the mark.
struct PrivacyCover: View {
    var body: some View {
        ZStack {
            Palette.paper.ignoresSafeArea()
            VStack(spacing: 12) {
                Image(systemName: "shield.lefthalf.filled").font(.system(size: 56)).foregroundStyle(Palette.accent)
                Text(verbatim: "sealctl").font(.system(size: 28, weight: .semibold, design: .monospaced)).foregroundStyle(Palette.ink)
            }
        }
        .accessibilityHidden(true)
    }
}

/// "Set a passcode first." (11.20)
struct NeedsScreenLockView: View {
    var body: some View {
        Page(onBack: nil) {
            Gap(48)
            Wordmark()
            TitleText("Set a passcode first")
            BodyText("Set a passcode first. sealctl keeps your words behind this phone's passcode.")
        } bottom: {
            PrimaryButton("Open settings") { Links.settings() }
        }
    }
}

/// The root item is gone (11.20), or another phone changed or removed the words (11.22).
struct WordsLostView: View {
    @Environment(AppModel.self) private var model
    let reason: WordsLostReason

    var body: some View {
        Page(onBack: nil) {
            Gap(48)
            Wordmark()
            switch reason {
            case .passcodeRemoved:
                BodyText("Your words were removed from this phone because its passcode was turned off. Restore them from iCloud Keychain or your card.")
            case .removedElsewhere:
                BodyText("Your words were removed on another phone.")
            }
        } bottom: {
            if reason == .removedElsewhere {
                SecondaryButton("Erase this phone") { restore() }
            }
            PrimaryButton("Restore") { restore() }
        }
    }

    private func restore() {
        guard let e = model.engine else { return }
        Task {
            await e.vault.erase()
            e.forgetPhoneKeys()
            await e.computePhase()
        }
    }
}
