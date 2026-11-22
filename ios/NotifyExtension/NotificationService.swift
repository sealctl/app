import EngineKit
import UserNotifications
import Vault

/// The Notification Service Extension (SPEC.md 10.1): about 30 seconds and 24 MB. It opens
/// the pushed request with the phone keys, answers it when it answers by itself, or rewrites
/// the notification with the request's text and buttons. On any failure or timeout the push
/// is delivered as the relay sent it.
final class NotificationService: UNNotificationServiceExtension, @unchecked Sendable {
    private var handler: ((UNNotificationContent) -> Void)?
    private var original: UNNotificationContent?
    private var work: Task<Void, Never>?

    override func didReceive(_ request: UNNotificationRequest, withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void) {
        handler = contentHandler
        original = request.content
        guard let content = request.content.mutableCopy() as? UNMutableNotificationContent else {
            contentHandler(request.content)
            return
        }
        let group = Bundle.main.object(forInfoDictionaryKey: "SealctlAppGroup") as? String ?? "group.com.sealctl.app"
        let keychainGroup = Bundle.main.object(forInfoDictionaryKey: "SealctlKeychainGroup") as? String
        let ext = ExtensionHandler(vault: KeychainVault(accessGroup: keychainGroup), files: SharedFiles.standard(group: group))
        let box = ContentBox(content)
        work = Task { [weak self] in
            let result = await ext.handle(box.content)
            self?.deliver(result ?? self?.original)
        }
    }

    override func serviceExtensionTimeWillExpire() {
        work?.cancel()
        deliver(original)
    }

    private func deliver(_ content: UNNotificationContent?) {
        guard let h = handler, let content else { return }
        handler = nil
        h(content)
    }
}

/// Carries the mutable content into the handler's task.
private final class ContentBox: @unchecked Sendable {
    let content: UNMutableNotificationContent
    init(_ c: UNMutableNotificationContent) { content = c }
}
