import Foundation
import SealCore

/// The outcome of the biometric gate of levels 2 and 3 (SPEC.md 9.6).
public enum GateResult: Sendable, Equatable {
    case passed
    case cancelled
    /// Locked after too many tries: refused until the phone is unlocked with its passcode.
    case lockedOut
    /// A face or finger was added or removed: the gate item is gone. The card comes first.
    case changed
    /// No biometrics on this phone, or none enrolled.
    case unavailable
    case failed(String)
}

/// The outcome of the words prompt (Face ID, Touch ID or the passcode).
public enum OwnerAuth: Sendable, Equatable {
    case passed
    case cancelled
    case failed(String)
}

/// Key storage (SPEC.md 7.2). Swift holds the root, words and phone keys only as the core's
/// objects, which zero their memory when released; raw bytes exist only between the keychain
/// and the object they become.
public protocol Vault: Sendable {
    /// A passcode is set (SPEC.md 11.20 `NeedsScreenLock`).
    func isDeviceSecure() async -> Bool
    /// Biometrics for `decide` and the level 2 and 3 screens.
    func biometrics() async -> Biometrics
    /// "Face ID", "Touch ID" or "Optic ID", for button titles.
    func biometryName() async -> String

    func hasRoot() async -> Bool
    func hasPhoneKeys() async -> Bool
    func hasWords() async -> Bool

    /// Stores the words (behind `.userPresence`), the root and the phone keys.
    func saveAll(words: Words) async throws
    /// The root, or nil while the phone is locked or when it is gone.
    func readRoot() async -> Root?
    func canReadRoot() async -> Bool
    /// The phone keys; readable after the first unlock since boot.
    func readPhoneKeys() async -> PhoneKeys?
    /// The words, after Face ID, Touch ID or the passcode.
    func readWords(reason: String) async -> (OwnerAuth, Words?)
    /// Face ID, Touch ID or the passcode, without reading anything.
    func authenticateOwner(reason: String) async -> OwnerAuth

    /// Levels 2 and 3: a fresh biometric match, no passcode, proven by reading the gate item.
    func gate(reason: String) async -> GateResult
    /// After an enrolment change and the card words: a new gate.
    func resetGate() async

    /// The iCloud Keychain copy (`com.sealctl.words.sync`): `backup_item_encode` bytes.
    func saveSyncBackup(_ item: Data) async -> Bool
    func readSyncBackup() async -> Data?
    func deleteSyncBackup() async

    /// Deletes every item this install made (Erase sealctl from this phone).
    func erase() async
}
