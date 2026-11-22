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
        await v.set(nextGate: .changed)
        #expect(await v.gate(reason: "x") == .changed)
    }
}
