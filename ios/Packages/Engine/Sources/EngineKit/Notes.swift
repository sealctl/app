import Foundation
import SealCore
import UserNotifications

/// Notification categories, actions and the request content (SPEC.md 10.1), shared by the
/// app and the Notification Service Extension.
public enum Notes {
    public static let relayCategory = "SEALCTL_REQUEST"
    public static let open = "REQUEST_OPEN"
    public static let agent = "REQUEST_AGENT"
    public static let own = "REQUEST_OWN"
    public static let keys = "REQUEST_KEYS"
    public static let app = "REQUEST_APP"

    public static func categories() -> Set<UNNotificationCategory> {
        func allow(_ id: String, _ title: String) -> UNNotificationAction {
            UNNotificationAction(identifier: id, title: title, options: [.authenticationRequired])
        }
        let deny = UNNotificationAction(identifier: "DENY", title: "Deny", options: [.destructive])
        let placeholder = Texts.hiddenPreview
        func cat(_ id: String, _ actions: [UNNotificationAction]) -> UNNotificationCategory {
            UNNotificationCategory(identifier: id, actions: actions, intentIdentifiers: [],
                                   hiddenPreviewsBodyPlaceholder: placeholder, options: [])
        }
        return [
            cat(relayCategory, []),
            cat(open, [allow("ALLOW_SESSION", "Allow for this session"), allow("ALLOW_ONCE", "Allow once"), deny]),
            cat(agent, [allow("ALLOW_REMEMBER", "Allow"), allow("ALLOW_ONCE", "Allow once"), deny]),
            cat(own, [allow("ALLOW_ONCE", "Allow once"), deny]),
            cat(keys, [allow("ALLOW_REMEMBER", "Allow"), deny]),
            cat(app, []),
        ]
    }

    /// The category for a request: buttons only for One tap (level 1); every level 2 and 3
    /// request, `old_words` and unknown kinds open the app (9.6 "Never at the lock screen").
    public static func category(_ verdict: Verdict) -> String {
        guard verdict.asking == .oneTap else { return app }
        switch verdict.kind {
        case .open: return open
        case .agent: return agent
        case .own: return own
        case .keys: return keys
        default: return app
        }
    }

    /// Fills a notification for a waiting request (11.7 "Notification text").
    public static func fill(_ content: UNMutableNotificationContent, _ w: Waiting, machineName: String, biometry: String) {
        let t = Texts.notification(Texts.facts(w, machineName: machineName), biometry: biometry)
        content.title = t.title
        content.body = t.body
        content.categoryIdentifier = category(w.verdict)
        content.threadIdentifier = w.machine.key
        content.userInfo = ["type": "request", "id": w.relay.id, "expires": w.deadline, "machine": w.machine.key]
        content.interruptionLevel = .timeSensitive
        content.relevanceScore = 1
        content.sound = .default
    }

    public static func requestContent(_ w: Waiting, machineName: String, biometry: String) -> UNMutableNotificationContent {
        let c = UNMutableNotificationContent()
        fill(c, w, machineName: machineName, biometry: biometry)
        return c
    }

    /// A quiet note: Notification Center only, no sound, no badge.
    public static func passive(_ title: String, body: String? = nil, userInfo: [String: String] = [:]) -> UNMutableNotificationContent {
        let c = UNMutableNotificationContent()
        c.title = title
        if let body { c.body = body }
        c.interruptionLevel = .passive
        c.userInfo = userInfo
        return c
    }

    public static func active(_ title: String, body: String? = nil, level: UNNotificationInterruptionLevel = .active,
                              userInfo: [String: String] = [:]) -> UNMutableNotificationContent {
        let c = UNMutableNotificationContent()
        c.title = title
        if let body { c.body = body }
        c.interruptionLevel = level
        c.sound = .default
        c.userInfo = userInfo
        c.categoryIdentifier = app
        return c
    }
}
