import Foundation
import Testing
@testable import SealCore

/// The protocol's test vectors through the generated Swift bindings (SPEC.md 16.1), so Swift,
/// Kotlin and Rust give the same bytes.
struct VectorsTests {
    static func load(_ name: String) throws -> [String: Any] {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Vectors"))
        return try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }

    let v: [String: Any]
    init() throws { v = try Self.load("vectors-v1") }

    func s(_ k: String) -> String { v[k] as? String ?? "" }
    func hex(_ d: Data) -> String { d.map { String(format: "%02x", $0) }.joined() }
    func bytes(_ hex: String) -> Data {
        var d = Data()
        var i = hex.startIndex
        while i < hex.endIndex {
            let j = hex.index(i, offsetBy: 2)
            d.append(UInt8(hex[i..<j], radix: 16)!)
            i = j
        }
        return d
    }

    @Test func wordsRootFingerprintPhoneKeys() throws {
        for set in ["A", "B"] {
            let words = try Words.parse(list: s("\(set).mnemonic").split(separator: " ").map(String.init))
            let root = Root.fromWords(words: words)
            #expect(hex(root.toBytes()) == s("\(set).root"))
            #expect(fingerprint(root: root) == s("\(set).fingerprint"))
            let keys = PhoneKeys.fromRoot(root: root)
            #expect(keys.publicId() == s("\(set).phone_identity_public_b64u"))
            #expect(keys.boxPublicKey() == s("\(set).phone_box_public_b64u"))
            let again = try PhoneKeys.fromBytes(bytes: keys.toBytes())
            #expect(again.publicId() == keys.publicId())
            #expect(try Words.fromEntropy(bytes: words.entropy()).list() == words.list())
        }
        let b = try Words.parse(list: s("B.mnemonic").split(separator: " ").map(String.init))
        #expect(hex(b.entropy()) == s("B.entropy"))
    }

    @Test func typedWordsByFourLetters() throws {
        let list = s("B.mnemonic").split(separator: " ").map { String($0.prefix(4)) }
        let words = try Words.parse(list: list)
        #expect(fingerprint(root: Root.fromWords(words: words)) == s("B.fingerprint"))
        var bad = list
        bad[3] = "zzzz"
        do {
            _ = try Words.parse(list: bad)
            Issue.record("zzzz parsed")
        } catch CoreError.UnknownWord(let index) {
            #expect(index == 3)
        }
        var sum = list
        sum[0] = "able"
        sum[1] = "able"
        #expect(throws: CoreError.Checksum) { try Words.parse(list: sum) }
        #expect(completeWord(prefix: "ocea").contains("ocean"))
        let e = wordEntry(prefix: "oce")
        #expect(e.nextLetters == ["a"])
    }

    @Test func stateBlobOpens() throws {
        let root = try Root.fromBytes(bytes: bytes(s("B.root")))
        _ = try stateOpen(root: root, blob: s("B.state_blob_b64u"))
        let empty = State(machines: [], answers: [], places: [], inventory: [], summaries: [], words: nil,
                          settings: Settings(relayBackup: true, keychainBackup: true, updated: 0), reports: [])
        let sealed = try stateSeal(root: root, plaintext: encodeState(state: empty))
        #expect(try decodeState(bytes: stateOpen(root: root, blob: sealed)).machines.isEmpty)
    }

    @Test func machineTagAndBackupItem() throws {
        #expect(try machineTag(machineKey: s("machine.public_b64u")) == s("machine.tag"))
        let words = try Words.parse(list: s("B.mnemonic").split(separator: " ").map(String.init))
        let item = try backupItemEncode(words: words, fingerprint: "qHWf", created: 1_795_251_600_000)
        #expect(item.count == 45)
        let back = try backupItemDecode(bytes: item)
        #expect(back.fingerprint == "qHWf")
        #expect(back.words.list() == words.list())
        #expect(cardChoices(words: words, position: 7).count == 4)
        #expect(cardWordMatches(words: words, position: 1, typed: "bulk"))
        #expect(!cardWordMatches(words: words, position: 1, typed: "sear"))
    }

    @Test func relaySigningVectors() throws {
        let r = try Self.load("relay-signing")
        let words = try Words.parse(list: s("B.mnemonic").split(separator: " ").map(String.init))
        let keys = PhoneKeys.fromRoot(root: Root.fromWords(words: words))
        let vectors = try #require(r["vectors"] as? [[String: Any]])
        var checked = 0
        for x in vectors where x["signer"] as? String == "phone" {
            let h = relayHeaders(keys: keys, method: x["method"] as! String, pathAndQuery: x["path"] as! String,
                                 unixTime: UInt64(x["time"] as! String)!, body: Data((x["body"] as! String).utf8))
            #expect(h.key == x["key"] as? String)
            #expect(h.signature == x["signature"] as? String)
            checked += 1
        }
        #expect(checked > 0)
    }

    @Test func expiredPairingCodeAndVersions() throws {
        #expect(throws: CoreError.Expired) { try PairingOffer.parse(text: s("pair.link")) }
        #expect(throws: CoreError.BadLink) { try PairingOffer.parse(text: "https://example.com/p#v=1") }
        #expect(protocolVersion() == "1")
        #expect(coreVersion().hasPrefix("0.7"))
        #expect(!appRulesVersion().isEmpty)
    }
}
