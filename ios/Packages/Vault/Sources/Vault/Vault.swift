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
    /// No gate on this phone yet: the card comes first, then the first gate is made (9.6).
    case noGate
    /// No biometrics on this phone, or none enrolled.
    case unavailable
    case failed(String)
}

/// What the gate does with what is stored (SPEC.md 9.6).
public enum GateStep: Sendable, Equatable {
    /// A gate exists, or existed: the prompt reads it (an unreadable one means `changed`).
    case check
    /// The card was just passed: the prompt makes a new gate.
    case make
    /// No gate, and no card passed since: two words from the card first (`noGate`).
    case cardFirst

    /// The first gate, like a new one after an enrolment change, is made only after the card,
    /// so a face or finger enrolled before then is never trusted on its own.
    public static func of(itemExists: Bool, made: Bool, cardPassed: Bool) -> GateStep {
        if itemExists || made { return .check }
        return cardPassed ? .make : .cardFirst
    }
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
    /// `noGate` before the first gate: the card comes first (`resetGate`).
    func gate(reason: String) async -> GateResult
    /// After two words from the card (an enrolment change, or before the first gate): removes
    /// any old gate and lets the next prompt make a new one.
    func resetGate() async

    /// The iCloud Keychain copy (`com.sealctl.words.sync`): `backup_item_encode` bytes.
    func saveSyncBackup(_ item: Data) async -> Bool
    func readSyncBackup() async -> Data?
    func deleteSyncBackup() async

    /// Deletes every item this install made (Erase sealctl from this phone).
    func erase() async
}
