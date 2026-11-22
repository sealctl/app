import Foundation
import LocalAuthentication
import Security
import SealCore

/// The keychain items of SPEC.md 7.2, all `kSecClassGenericPassword` in the shared access
/// group so the Notification Service Extension can read the phone keys and the root.
///
/// | Service | Holds | Accessibility | Access control |
/// | `com.sealctl.root` | root | when passcode set, this device | none |
/// | `com.sealctl.words` | words entropy | when passcode set, this device | `.userPresence` |
/// | `com.sealctl.phone` | phone keys | after first unlock, this device | none |
/// | `com.sealctl.words.sync` | backup item | when unlocked, synchronizable | none |
/// | `com.sealctl.gate` | 32 random bytes | when passcode set, this device | `.biometryCurrentSet` |
public actor KeychainVault: Vault {
    public static let root = "com.sealctl.root"
    public static let words = "com.sealctl.words"
    public static let phone = "com.sealctl.phone"
    public static let sync = "com.sealctl.words.sync"
    public static let gateItem = "com.sealctl.gate"

    private var accessGroup: String?
    private let defaults: UserDefaults

    /// `accessGroup` is `$(AppIdentifierPrefix)com.sealctl.shared`; nil uses the app's own group.
    public init(accessGroup: String?, defaults: UserDefaults = .standard) {
        self.accessGroup = accessGroup?.isEmpty == false ? accessGroup : nil
        self.defaults = defaults
    }

    // MARK: state of the phone

    public func isDeviceSecure() -> Bool {
        LAContext().canEvaluatePolicy(.deviceOwnerAuthentication, error: nil)
    }

    public func biometrics() -> Biometrics {
        let ctx = LAContext()
        var error: NSError?
        if ctx.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) { return .available }
        if let e = error, e.code == LAError.biometryLockout.rawValue { return .lockedOut }
        return .unavailable
    }

    public func biometryName() -> String {
        let ctx = LAContext()
        _ = ctx.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
        switch ctx.biometryType {
        case .touchID: return "Touch ID"
        case .opticID: return "Optic ID"
        default: return "Face ID"
        }
    }

    public func hasRoot() -> Bool { exists(Self.root) }
    public func hasPhoneKeys() -> Bool { exists(Self.phone) }
    public func hasWords() -> Bool { exists(Self.words) }

    // MARK: words, root, phone keys

    public func saveAll(words: Words) throws {
        let root = Root.fromWords(words: words)
        let fp = fingerprint(root: root)
        let keys = PhoneKeys.fromRoot(root: root)
        var entropy = words.entropy()
        defer { entropy.resetBytes(in: 0..<entropy.count) }
        var rootBytes = root.toBytes()
        defer { rootBytes.resetBytes(in: 0..<rootBytes.count) }
        var keyBytes = keys.toBytes()
        defer { keyBytes.resetBytes(in: 0..<keyBytes.count) }
        for s in [Self.words, Self.root, Self.phone] { delete(s) }
        try add(Self.words, account: fp, data: entropy, protection: .control(.userPresence))
        try add(Self.root, account: fp, data: rootBytes, protection: .accessible(kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly))
        try add(Self.phone, account: fp, data: keyBytes, protection: .accessible(kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly))
    }

    public func readRoot() -> Root? {
        guard var bytes = copy(Self.root, context: nil) else { return nil }
        defer { bytes.resetBytes(in: 0..<bytes.count) }
        return try? Root.fromBytes(bytes: bytes)
    }

    public func canReadRoot() -> Bool { readRoot() != nil }

    public func readPhoneKeys() -> PhoneKeys? {
        guard var bytes = copy(Self.phone, context: nil) else { return nil }
        defer { bytes.resetBytes(in: 0..<bytes.count) }
        return try? PhoneKeys.fromBytes(bytes: bytes)
    }

    public func readWords(reason: String) async -> (OwnerAuth, Words?) {
        let ctx = LAContext()
        ctx.localizedReason = reason
        let auth = await evaluate(ctx, .deviceOwnerAuthentication, reason)
        guard auth == .passed else { return (auth, nil) }
        guard var bytes = copy(Self.words, context: ctx) else { return (.failed("words item"), nil) }
        defer { bytes.resetBytes(in: 0..<bytes.count) }
        guard let w = try? Words.fromEntropy(bytes: bytes) else { return (.failed("words"), nil) }
        return (.passed, w)
    }

    public func authenticateOwner(reason: String) async -> OwnerAuth {
        await evaluate(LAContext(), .deviceOwnerAuthentication, reason)
    }

    private func evaluate(_ ctx: LAContext, _ policy: LAPolicy, _ reason: String) async -> OwnerAuth {
        do {
            return try await ctx.evaluatePolicy(policy, localizedReason: reason) ? .passed : .failed("denied")
        } catch let e as LAError {
            switch e.code {
            case .userCancel, .appCancel, .systemCancel, .userFallback: return .cancelled
            default: return .failed("\(e.code.rawValue)")
            }
        } catch {
            return .failed("auth")
        }
    }

    // MARK: the gate (levels 2 and 3, SPEC.md 9.6)

    private static let gateMade = "com.sealctl.gate.made"

    public func gate(reason: String) async -> GateResult {
        let ctx = LAContext()
        ctx.localizedFallbackTitle = ""
        ctx.touchIDAuthenticationAllowableReuseDuration = 0
        var error: NSError?
        guard ctx.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) else {
            if error?.code == LAError.biometryLockout.rawValue { return .lockedOut }
            return .unavailable
        }
        do {
            guard try await ctx.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, localizedReason: reason) else {
                return .failed("denied")
            }
        } catch let e as LAError {
            switch e.code {
            case .userCancel, .appCancel, .systemCancel, .userFallback: return .cancelled
            case .biometryLockout: return .lockedOut
            case .biometryNotEnrolled, .biometryNotAvailable: return .unavailable
            default: return .failed("\(e.code.rawValue)")
            }
        } catch {
            return .failed("auth")
        }
        // The read itself needs the match: the item's access control is `.biometryCurrentSet`.
        var status: OSStatus = errSecSuccess
        if var bytes = copy(Self.gateItem, context: ctx, status: &status) {
            defer { bytes.resetBytes(in: 0..<bytes.count) }
            return bytes.count == 32 ? .passed : .failed("gate")
        }
        if defaults.bool(forKey: Self.gateMade) { return .changed }
        return makeGate(ctx) ? .passed : .failed("gate \(status)")
    }

    private func makeGate(_ ctx: LAContext) -> Bool {
        var secret = Data(count: 32)
        let ok = secret.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 32, $0.baseAddress!) } == errSecSuccess
        defer { secret.resetBytes(in: 0..<32) }
        guard ok else { return false }
        delete(Self.gateItem)
        guard (try? add(Self.gateItem, account: "gate", data: secret, protection: .control(.biometryCurrentSet))) != nil else { return false }
        defaults.set(true, forKey: Self.gateMade)
        return true
    }

    public func resetGate() {
        delete(Self.gateItem)
        defaults.removeObject(forKey: Self.gateMade)
    }

    // MARK: iCloud Keychain copy

    public func saveSyncBackup(_ item: Data) -> Bool {
        delete(Self.sync, synchronizable: true)
        var q = base(Self.sync, synchronizable: true)
        q[kSecAttrAccount as String] = "words"
        q[kSecValueData as String] = item
        q[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
        return addRetryingGroup(q) == errSecSuccess
    }

    public func readSyncBackup() -> Data? {
        var q = base(Self.sync, synchronizable: true)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess else { return nil }
        return out as? Data
    }

    public func deleteSyncBackup() { delete(Self.sync, synchronizable: true) }

    public func erase() {
        for s in [Self.words, Self.root, Self.phone, Self.gateItem, "com.sealctl.root.old", "com.sealctl.words.old"] { delete(s) }
        defaults.removeObject(forKey: Self.gateMade)
    }

    // MARK: plumbing

    private enum Protection {
        case accessible(CFString)
        /// When passcode set, this device only, with access control.
        case control(SecAccessControlCreateFlags)
    }

    private func base(_ service: String, synchronizable: Bool = false) -> [String: Any] {
        var q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecUseDataProtectionKeychain as String: true,
        ]
        if synchronizable { q[kSecAttrSynchronizable as String] = true }
        if let accessGroup { q[kSecAttrAccessGroup as String] = accessGroup }
        return q
    }

    private func add(_ service: String, account: String, data: Data, protection: Protection) throws {
        func query(passcodeClass: CFString) -> [String: Any] {
            var q = base(service)
            q[kSecAttrAccount as String] = account
            q[kSecValueData as String] = data
            switch protection {
            case .accessible(let a):
                q[kSecAttrAccessible as String] = a == kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly ? passcodeClass : a
            case .control(let flags):
                q[kSecAttrAccessControl as String] = SecAccessControlCreateWithFlags(nil, passcodeClass, flags, nil)
            }
            return q
        }
        var status = addRetryingGroup(query(passcodeClass: kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly))
        #if targetEnvironment(simulator)
        // A simulator has no passcode of its own and may refuse the passcode class; the
        // access control (user presence, current biometrics) stays as it is.
        if status != errSecSuccess && status != errSecDuplicateItem {
            status = addRetryingGroup(query(passcodeClass: kSecAttrAccessibleWhenUnlockedThisDeviceOnly))
        }
        #endif
        guard status == errSecSuccess else { throw VaultError.keychain(status) }
    }

    /// Adds an item; without the keychain-sharing entitlement (an unsigned build) the access
    /// group is dropped and the app's own group is used.
    private func addRetryingGroup(_ q: [String: Any]) -> OSStatus {
        var status = SecItemAdd(q as CFDictionary, nil)
        if status == errSecMissingEntitlement, accessGroup != nil {
            accessGroup = nil
            var q2 = q
            q2.removeValue(forKey: kSecAttrAccessGroup as String)
            status = SecItemAdd(q2 as CFDictionary, nil)
        }
        return status
    }

    private func copy(_ service: String, context: LAContext?) -> Data? {
        var status: OSStatus = errSecSuccess
        return copy(service, context: context, status: &status)
    }

    private func copy(_ service: String, context: LAContext?, status: inout OSStatus) -> Data? {
        var q = base(service)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        if let context {
            q[kSecUseAuthenticationContext as String] = context
        } else {
            // Never prompt from a plain read: the root reads nil while the phone is locked.
            let ctx = LAContext()
            ctx.interactionNotAllowed = true
            q[kSecUseAuthenticationContext as String] = ctx
        }
        var out: CFTypeRef?
        status = SecItemCopyMatching(q as CFDictionary, &out)
        if status == errSecMissingEntitlement, accessGroup != nil {
            accessGroup = nil
            return copy(service, context: context, status: &status)
        }
        return status == errSecSuccess ? out as? Data : nil
    }

    private func exists(_ service: String) -> Bool {
        var q = base(service)
        q[kSecReturnAttributes as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        let ctx = LAContext()
        ctx.interactionNotAllowed = true
        q[kSecUseAuthenticationContext as String] = ctx
        var out: CFTypeRef?
        var status = SecItemCopyMatching(q as CFDictionary, &out)
        if status == errSecMissingEntitlement, accessGroup != nil {
            accessGroup = nil
            q.removeValue(forKey: kSecAttrAccessGroup as String)
            status = SecItemCopyMatching(q as CFDictionary, &out)
        }
        // Locked or behind access control still means the item is there.
        return status == errSecSuccess || status == errSecInteractionNotAllowed || status == errSecAuthFailed
    }

    private func delete(_ service: String, synchronizable: Bool = false) {
        var q = base(service, synchronizable: synchronizable)
        if synchronizable { q[kSecAttrSynchronizable as String] = kSecAttrSynchronizableAny }
        var status = SecItemDelete(q as CFDictionary)
        if status == errSecMissingEntitlement, accessGroup != nil {
            accessGroup = nil
            q.removeValue(forKey: kSecAttrAccessGroup as String)
            status = SecItemDelete(q as CFDictionary)
        }
    }
}

public enum VaultError: Error, Sendable, Equatable {
    case keychain(OSStatus)
}
