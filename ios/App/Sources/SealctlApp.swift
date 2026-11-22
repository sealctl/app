import DesignSystem
import Engine
import EngineKit
import Places
import SealCore
import SwiftUI
import UIKit
import UserNotifications
import Vault

/// Build settings from Info.plist (`ios/Config/*.xcconfig`). Debug builds also read test
/// overrides from the launch environment: the relay, a shortened level 3 delay, a reset.
enum BuildConfig {
    static func string(_ key: String) -> String? {
        (Bundle.main.object(forInfoDictionaryKey: key) as? String).flatMap { $0.isEmpty ? nil : $0 }
    }

    static var relayURL: String {
        #if DEBUG
        if let r = ProcessInfo.processInfo.environment["SEALCTL_RELAY"], r.hasPrefix("http") { return r }
        #endif
        return string("SealctlRelayURL") ?? "https://relay.sealctl.com"
    }

    static var testDelaySecs: Int {
        #if DEBUG
        if let d = ProcessInfo.processInfo.environment["SEALCTL_TEST_DELAY"].flatMap(Int.init) { return d }
        return string("SealctlTestDelaySecs").flatMap(Int.init) ?? 0
        #else
        return 0
        #endif
    }

    static var resetForTests: Bool {
        #if DEBUG
        return ProcessInfo.processInfo.arguments.contains("-resetForTests")
        #else
        return false
        #endif
    }

    static var keychainGroup: String? { string("SealctlKeychainGroup") }
    static var appGroup: String { string("SealctlAppGroup") ?? "group.com.sealctl.app" }
    static var version: String { string("CFBundleShortVersionString") ?? "1.0.0" }
    static var build: String { string("CFBundleVersion") ?? "1" }
    static var sandboxPush: Bool {
        #if DEBUG
        return true
        #else
        return false
        #endif
    }
}

/// Everything the screens share: the engine, the router, typed words.
@MainActor
@Observable
final class AppModel {
    var engine: AppEngine?
    let router = Router()
    let places = Places()
    @ObservationIgnored let notifier = AppNotifier()
    @ObservationIgnored private var started = false

    func start() async {
        guard !started else { return }
        started = true
        let files = SharedFiles.standard(group: BuildConfig.appGroup)
        let vault = KeychainVault(accessGroup: BuildConfig.keychainGroup)
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        let dbURL = support.appendingPathComponent("sealctl.db")
        if BuildConfig.resetForTests {
            await vault.erase()
            await vault.deleteSyncBackup()
            for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: dbURL.path + suffix) }
            files.removeAll()
            UserDefaults.standard.removeObject(forKey: "com.sealctl.installed")
        }
        guard let db = try? Database(path: dbURL.path) else { return }
        try? (dbURL as NSURL).setResourceValue(URLFileProtection.completeUntilFirstUserAuthentication, forKey: .fileProtectionKey)
        let config = EngineConfig(relayURL: BuildConfig.relayURL, testDelaySecs: BuildConfig.testDelaySecs,
                                  sandboxPush: BuildConfig.sandboxPush, version: BuildConfig.version, build: BuildConfig.build)
        let e = await AppEngine(vault: vault, db: db, config: config, files: files, notifier: notifier, places: places)
        engine = e
        AppDelegate.engine = e
        AppDelegate.model = self
        await e.computePhase()
        await e.monitorPlaces()
        if let pending = AppDelegate.pendingToken { await e.registerPush(token: pending) }
        await e.onForeground()
    }
}

@main
struct SealctlApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @SwiftUI.State private var model = AppModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .environment(model.router)
                .tint(Palette.accent)
                .task { await model.start() }
                .onOpenURL { url in handle(url) }
                .onContinueUserActivity(NSUserActivityTypeBrowsingWeb) { a in
                    if let u = a.webpageURL { handle(u) }
                }
        }
        .onChange(of: scenePhase) { _, phase in
            guard let e = model.engine else { return }
            Task {
                switch phase {
                case .active:
                    await e.computePhase()
                    await e.onForeground()
                case .background:
                    await e.onBackground()
                default: break
                }
            }
        }
    }

    /// A pairing link opened outside the app leads to the scanner (SPEC.md 11.5): the app's
    /// own camera is the proof of proximity.
    private func handle(_ url: URL) {
        let s = url.absoluteString
        guard s.hasPrefix("https://sealctl.com/p") || s.hasPrefix("sealctl:") else { return }
        model.router.stack.removeAll { if case .pair = $0 { return true }; return false }
        model.router.push(.pair(fromLink: true))
    }
}
