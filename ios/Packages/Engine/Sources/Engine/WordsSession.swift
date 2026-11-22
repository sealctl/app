import Foundation
import EngineKit
import Observation
import SealCore
import Vault

/// The words on this phone: making them, showing them in the protected view, the card checks
/// and restoring. The `Words` object lives only while one of these screens is open.
@MainActor
@Observable
public final class WordsSession {
    @ObservationIgnored weak var engine: AppEngine?
    @ObservationIgnored private var session: Words?

    /// The 24 words for the protected view, or nil when closed.
    public private(set) var shown: [String]?
    public private(set) var fingerprintText: String?

    public static let reason = "Face ID protects showing and changing your 24 words."

    nonisolated init() {}

    public var hasSession: Bool { session != nil }

    /// Step 4 [Show my words]: Face ID, Touch ID or the passcode, then the words are made and
    /// stored with the root and the phone keys.
    public func create() async -> OwnerAuth {
        guard let engine else { return .failed("no engine") }
        if await engine.vault.hasWords(), await engine.vault.hasRoot() { return await show() }
        let auth = await engine.vault.authenticateOwner(reason: Self.reason)
        guard auth == .passed else { return auth }
        do {
            let w = try Words.generate()
            try await engine.vault.saveAll(words: w)
            engine.forgetPhoneKeys()
            open(w)
            return .passed
        } catch {
            return .failed("\(error)")
        }
    }

    /// Shows the stored words after Face ID, Touch ID or the passcode.
    public func show() async -> OwnerAuth {
        guard let engine else { return .failed("no engine") }
        let (auth, w) = await engine.vault.readWords(reason: Self.reason)
        if let w { open(w) }
        return auth
    }

    /// Opens the words for a card check without showing them.
    public func unlockForCheck() async -> OwnerAuth {
        let r = await show()
        shown = nil
        return r
    }

    private func open(_ w: Words) {
        session = w
        shown = w.list()
        fingerprintText = fingerprint(root: Root.fromWords(words: w))
    }

    /// Hides the words; the session stays for the check that follows.
    public func hide() { shown = nil }

    /// Forgets the words (screen closed, check done).
    public func release() {
        shown = nil
        session = nil
    }

    public func positions(count: Int, groups: Int) -> [Int] {
        cardPositions(count: UInt32(count), groups: UInt32(groups)).map { Int($0) }
    }

    public func choices(_ position: Int) -> [String] {
        session.map { cardChoices(words: $0, position: UInt32(position)) } ?? []
    }

    public func matches(_ position: Int, _ typed: String) -> Bool {
        session.map { cardWordMatches(words: $0, position: UInt32(position), typed: typed) } ?? false
    }

    /// Step 6 passed: the card is written; the words backup goes to iCloud Keychain.
    @discardableResult
    public func cardChecked() async -> Bool? {
        guard let engine, let fp = fingerprintText else { return nil }
        await engine.apply(.setWords(words: WordsInfo(fingerprint: fp, writtenOn: Texts.isoDate(nowMs()), lastCheck: nil,
                                                      retired: [], updated: 0)))
        await engine.applyLocal(.setOnboardingStep(step: 7))
        let saved = await saveBackup()
        release()
        await engine.computePhase()
        return saved
    }

    /// Writes the iCloud Keychain item while the words are open. Nil when turned off.
    public func saveBackup() async -> Bool? {
        guard let engine, let w = session, let fp = fingerprintText, engine.state.settings.keychainBackup else { return nil }
        guard var item = try? backupItemEncode(words: w, fingerprint: fp, created: UInt64(nowMs())) else { return false }
        defer { item.resetBytes(in: 0..<item.count) }
        return await engine.vault.saveSyncBackup(item)
    }

    /// Restore: stores typed or backed-up words after Face ID, Touch ID or the passcode.
    public func restore(_ w: Words) async -> OwnerAuth {
        guard let engine else { return .failed("no engine") }
        let auth = await engine.vault.authenticateOwner(reason: Self.reason)
        guard auth == .passed else { return auth }
        do {
            try await engine.vault.saveAll(words: w)
        } catch {
            return .failed("\(error)")
        }
        engine.forgetPhoneKeys()
        open(w)
        shown = nil
        return .passed
    }

    /// After a restore: the words facts from the relay, or written today.
    public func restored(_ fp: String) async {
        guard let engine else { return }
        if engine.state.words?.fingerprint != fp {
            await engine.apply(.setWords(words: WordsInfo(fingerprint: fp, writtenOn: Texts.isoDate(nowMs()), lastCheck: nil,
                                                          retired: [], updated: 0)))
        }
        await engine.applyLocal(.setOnboardingStep(step: 7))
        UserDefaults.standard.set(true, forKey: AppEngine.installedKey)
    }
}
