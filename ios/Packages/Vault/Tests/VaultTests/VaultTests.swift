import Foundation
import Testing
import SealCore
@testable import Vault

/// The keychain items on the iOS simulator (never against a Mac's own keychain).
#if os(iOS)
@Suite(.serialized)
struct KeychainVaultTests {
    let vault = KeychainVault(accessGroup: nil, defaults: UserDefaults(suiteName: "vault-tests")!)

    @Test func savesAndReadsRootAndPhoneKeys() async throws {
        await vault.erase()
        #expect(await !vault.hasRoot())
        let words = try Words.generate()
        do {
            try await vault.saveAll(words: words)
        } catch VaultError.keychain(let status) where status == errSecMissingEntitlement {
            // A test runner without keychain entitlements (unsigned) can't hold items.
            Issue.record("keychain unavailable to this test runner: \(status)", severity: .warning)
            return
        }
        #expect(await vault.hasRoot())
        #expect(await vault.hasPhoneKeys())
        #expect(await vault.hasWords())
        let root = try #require(await vault.readRoot())
        #expect(fingerprint(root: root) == fingerprint(root: Root.fromWords(words: words)))
        let keys = try #require(await vault.readPhoneKeys())
        #expect(keys.publicId() == PhoneKeys.fromRoot(root: root).publicId())
        await vault.erase()
        #expect(await vault.readRoot() == nil)
        #expect(await !vault.hasPhoneKeys())
    }

    @Test func syncBackupRoundTrip() async throws {
        let words = try Words.generate()
        let item = try backupItemEncode(words: words, fingerprint: "abcd", created: 1)
        if await vault.saveSyncBackup(item) {
            let back = try #require(await vault.readSyncBackup())
            #expect(try backupItemDecode(bytes: back).words.list() == words.list())
            await vault.deleteSyncBackup()
            #expect(await vault.readSyncBackup() == nil)
        }
    }
}
#endif

struct MemoryVaultTests {
    @Test func lockedPhoneReadsNoRootButKeys() async throws {
        let v = MemoryVault()
        try await v.saveAll(words: try Words.generate())
        await v.set(locked: true)
        #expect(await v.readRoot() == nil)
        #expect(await v.readPhoneKeys() != nil)
        await v.resetGate()
        await v.set(nextGate: .changed)
        #expect(await v.gate(reason: "x") == .changed)
    }

    /// SPEC.md 9.6: the first gate needs two words from the card, like a new one after an
    /// enrolment change; a phone without biometrics keeps the card fallback.
    @Test func firstGateNeedsTheCard() async throws {
        let v = MemoryVault()
        try await v.saveAll(words: try Words.generate())
        #expect(await v.gate(reason: "x") == .noGate)
        #expect(await v.gate(reason: "x") == .noGate)
        await v.resetGate()
        #expect(await v.gate(reason: "x") == .passed)
        // Made: later prompts check it, with no card.
        #expect(await v.gate(reason: "x") == .passed)
        await v.erase()
        #expect(await v.gate(reason: "x") == .noGate)
        await v.set(biometrics: .unavailable)
        #expect(await v.gate(reason: "x") == .unavailable)
    }

    /// The card allows the one prompt that follows it: a cancelled prompt means the card again,
    /// and a card left for longer than the window allows nothing (9.6).
    @Test func theCardAllowsOnePrompt() async throws {
        let v = MemoryVault()
        try await v.saveAll(words: try Words.generate())
        await v.resetGate()
        await v.set(nextGate: .cancelled)
        #expect(await v.gate(reason: "x") == .cancelled)
        await v.set(nextGate: .passed)
        #expect(await v.gate(reason: "x") == .noGate)
        var card = GateAllowance()
        let before = card.take(now: 10)
        card.allow(now: 10)
        let first = card.take(now: 11), second = card.take(now: 12)
        card.allow(now: 10)
        let late = card.take(now: 10 + GateAllowance.window)
        #expect(!before)
        #expect(first)
        #expect(!second)
        #expect(!late)
    }

    @Test func gateSteps() {
        #expect(GateStep.of(itemExists: false, made: false, cardPassed: false) == .cardFirst)
        #expect(GateStep.of(itemExists: false, made: false, cardPassed: true) == .make)
        #expect(GateStep.of(itemExists: true, made: false, cardPassed: false) == .check)
        #expect(GateStep.of(itemExists: false, made: true, cardPassed: false) == .check)
        #expect(GateStep.of(itemExists: true, made: true, cardPassed: true) == .check)
    }
}
