import Engine
import EngineKit
import SwiftUI
import UIKit
import UserNotifications

/// Push registration, notification actions and taps (SPEC.md 10.1).
final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    @MainActor static var engine: AppEngine?
    @MainActor static weak var model: AppModel?
    /// This launch's APNs token. Kept: before the words exist the engine can't register it,
    /// and iOS gives it again only at the next launch.
    @MainActor static var pendingToken: String?

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.setNotificationCategories(Notes.categories())
        application.registerForRemoteNotifications()
        return true
    }

    /// Custom keyboards are refused app-wide (SPEC.md 7.2).
    func application(_ application: UIApplication,
                     shouldAllowExtensionPointIdentifier extensionPointIdentifier: UIApplication.ExtensionPointIdentifier) -> Bool {
        extensionPointIdentifier != .keyboard
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        let hex = deviceToken.map { String(format: "%02x", $0) }.joined()
        Task { @MainActor in
            AppDelegate.pendingToken = hex
            if let e = AppDelegate.engine { await e.registerPush(token: hex) }
        }
    }

    /// Registers this launch's token when the engine has not stored it yet (after onboarding,
    /// or when the relay was down at the last try).
    @MainActor
    static func registerPendingToken(_ e: AppEngine) async {
        if let t = pendingToken, e.local.device.token != t { await e.registerPush(token: t) }
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        Log.note("push registration failed: \(type(of: error))")
    }

    /// In the foreground the approval card is already on screen: no banner for requests.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification)
        async -> UNNotificationPresentationOptions {
        let content = notification.request.content
        let type = content.userInfo["type"] as? String
        let id = content.userInfo["id"] as? String
        let isPush = notification.request.trigger is UNPushNotificationTrigger
        let category = content.categoryIdentifier
        let isRequest = type == "request" || category.hasPrefix("REQUEST") || category == Notes.relayCategory
        if let type, isPush {
            await MainActor.run {
                if let e = AppDelegate.engine { Task { await e.onPush(type: type, id: id) } }
            }
        }
        return isRequest ? [] : [.banner, .list, .sound]
    }

    /// A tap or an action button. Actions run in the background inside a background task;
    /// Allow actions carry `.authenticationRequired`, so a locked iPhone asks for its unlock.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let info = response.notification.request.content.userInfo
        let id = info["id"] as? String
        let screen = info["screen"] as? String
        let action = response.actionIdentifier
        await AppDelegate.inBackgroundTask {
            await AppDelegate.respond(id: id, screen: screen, action: action)
        }
    }

    @MainActor
    static func inBackgroundTask(_ work: @MainActor () async -> Void) async {
        let app = UIApplication.shared
        let box = TaskBox()
        box.id = app.beginBackgroundTask { [box] in
            app.endBackgroundTask(box.id)
            box.id = .invalid
        }
        await work()
        if box.id != .invalid { app.endBackgroundTask(box.id) }
    }

    @MainActor
    static func respond(id: String?, screen: String?, action: String) async {
        // The app may have been launched by this tap: wait for the engine.
        for _ in 0..<50 where engine == nil { try? await Task.sleep(for: .milliseconds(100)) }
        guard let e = engine, let router = model?.router else { return }
        if action != UNNotificationDefaultActionIdentifier && action != UNNotificationDismissActionIdentifier, let id {
            await e.answerFromNotification(id, action: action)
            return
        }
        if let id {
            e.focusRequest = id
            if !e.waiting.contains(where: { $0.relay.id == id }) { await e.catchUp() }
            if let w = e.waiting.first(where: { $0.relay.id == id }), w.verdict.asking == .inApp {
                router.stack.removeAll { if case .sensitive = $0 { return true }; return false }
                router.push(.sensitive(id))
            }
        }
        if let screen {
            if screen.hasPrefix("report:") { router.push(.report(String(screen.dropFirst(7)))) }
            if screen.hasPrefix("delayed:") { router.push(.delayed(String(screen.dropFirst(8)))) }
            if screen == "place" { router.push(.places) }
        }
    }
}

@MainActor
final class TaskBox {
    var id: UIBackgroundTaskIdentifier = .invalid
}

/// Notifications through `UNUserNotificationCenter`.
@MainActor
final class AppNotifier: Notifier {
    private let center = UNUserNotificationCenter.current()

    func post(id: String, content: UNNotificationContent, at: Date?) async {
        let trigger: UNNotificationTrigger? = at.map {
            UNTimeIntervalNotificationTrigger(timeInterval: max(1, $0.timeIntervalSinceNow), repeats: false)
        }
        try? await center.add(UNNotificationRequest(identifier: id, content: content, trigger: trigger))
    }

    func remove(ids: [String]) async {
        if ids.isEmpty {
            center.removeAllDeliveredNotifications()
            center.removeAllPendingNotificationRequests()
            return
        }
        center.removeDeliveredNotifications(withIdentifiers: ids)
        center.removePendingNotificationRequests(withIdentifiers: ids)
    }

    /// iOS can't remove a notification at a set time: on launch, foreground and answers, the
    /// app removes delivered requests that expired or were answered, and the passive notes
    /// of answers made by the extension.
    func removeStale(now: Int64, answered: Set<String>) async {
        let delivered = await center.deliveredNotifications()
        var gone: [String] = []
        for n in delivered {
            let info = n.request.content.userInfo
            if info["answered"] != nil { gone.append(n.request.identifier); continue }
            if let id = info["id"] as? String, answered.contains(id) { gone.append(n.request.identifier); continue }
            let expires = (info["expires"] as? NSNumber)?.int64Value ?? Int64(info["expires"] as? String ?? "") ?? 0
            if expires > 0 && expires < now { gone.append(n.request.identifier) }
        }
        if !gone.isEmpty { center.removeDeliveredNotifications(withIdentifiers: gone) }
    }

    func allowed() async -> Bool {
        let s = await center.notificationSettings()
        return s.authorizationStatus == .authorized || s.authorizationStatus == .provisional
    }

    func setBadge(_ n: Int) async {
        try? await center.setBadgeCount(n)
    }

    func timeSensitiveOn() async -> Bool {
        await center.notificationSettings().timeSensitiveSetting == .enabled
    }

    /// Onboarding step 8: `.alert`, `.sound`, `.badge`.
    func ask() async -> Bool {
        (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
    }
}
