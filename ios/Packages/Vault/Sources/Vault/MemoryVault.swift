import Foundation
import SealCore

/// A vault in memory, for the engine's unit tests on a Mac (whose own keychain the tests
/// never touch). The prompts answer with the results the test sets.
public actor MemoryVault: Vault {
    private var words: Data?
    private var root: Data?
    private var phone: Data?
    private var sync: Data?
    private var gateMade = false
    private var cardPassed = false
    public var secure = true
    public var locked = false
    public var biometricsState: Biometrics = .available
    public var nextGate: GateResult = .passed
    public var nextOwner: OwnerAuth = .passed
    public private(set) var gateReasons: [String] = []

    public init() {}

    public func set(locked: Bool) { self.locked = locked }
    public func set(nextGate: GateResult) { self.nextGate = nextGate }
    public func set(nextOwner: OwnerAuth) { self.nextOwner = nextOwner }
    public func set(biometrics: Biometrics) { biometricsState = biometrics }
    public func set(secure: Bool) { self.secure = secure }
    /// The passcode was turned off: iOS deletes the passcode-class items.
    public func dropPasscodeItems() { root = nil; words = nil }

    public func isDeviceSecure() -> Bool { secure }
    public func biometrics() -> Biometrics { biometricsState }
    public func biometryName() -> String { "Face ID" }
    public func hasRoot() -> Bool { root != nil }
    public func hasPhoneKeys() -> Bool { phone != nil }
    public func hasWords() -> Bool { words != nil }

    public func saveAll(words w: Words) throws {
        let r = Root.fromWords(words: w)
        words = w.entropy()
        root = r.toBytes()
        phone = PhoneKeys.fromRoot(root: r).toBytes()
    }

    public func readRoot() -> Root? {
        guard !locked, let root else { return nil }
        return try? Root.fromBytes(bytes: root)
    }

    public func canReadRoot() -> Bool { readRoot() != nil }

    public func readPhoneKeys() -> PhoneKeys? {
        guard let phone else { return nil }
        return try? PhoneKeys.fromBytes(bytes: phone)
    }

    public func readWords(reason: String) -> (OwnerAuth, Words?) {
        guard nextOwner == .passed else { return (nextOwner, nil) }
        guard let words, let w = try? Words.fromEntropy(bytes: words) else { return (.failed("words item"), nil) }
        return (.passed, w)
    }

    public func authenticateOwner(reason: String) -> OwnerAuth { nextOwner }

    public func gate(reason: String) -> GateResult {
        gateReasons.append(reason)
        if biometricsState == .unavailable { return .unavailable }
        if biometricsState == .lockedOut { return .lockedOut }
        // The same rule as the keychain vault (9.6): the first gate needs the card.
        // The card allows the one prompt that follows it, whatever that prompt answers.
        let step = GateStep.of(itemExists: false, made: gateMade, cardPassed: !gateMade && cardPassed)
        if step == .cardFirst { return .noGate }
        if step == .make { cardPassed = false }
        let r = nextGate
        if r == .passed { gateMade = true }
        return r
    }

    /// The card was passed: the next prompt makes the gate.
    public func resetGate() { gateMade = false; cardPassed = true; nextGate = .passed }

    public func saveSyncBackup(_ item: Data) -> Bool { sync = item; return true }
    public func readSyncBackup() -> Data? { sync }
    public func deleteSyncBackup() { sync = nil }

    public func erase() {
        words = nil; root = nil; phone = nil; gateMade = false; cardPassed = false
    }
}
