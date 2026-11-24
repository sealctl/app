import Testing
import EngineKit
import SealCore

/// The Activity rows of SPEC.md 11.12, through the shared crate as the screen gets them.
struct ActivityRowTests {
    let macMini = Machine(key: String(repeating: "A", count: 43), boxKey: "", name: "dev@Devs-Mac-mini.local", os: "macOS 26.1",
                          model: nil, hint: nil, pairedAt: 0, nickname: nil, lastSeen: nil, lastStatus: nil, tagShown: false,
                          flagged: false, relay: "", updated: 0, deleted: false)

    func entry(_ key: String, _ outcome: String, kind: String? = nil, agent: String? = nil, repo: String? = nil,
               command: String? = nil, machine: String? = nil) -> UsageEntry {
        UsageEntry(time: 0, machine: machine ?? macMini.key, key: key, agent: agent, repo: repo, command: command, outcome: outcome, kind: kind)
    }

    @Test func exampleRows() {
        // web-relay/web-relay-token · dev · scan · dev@Devs-Mac-mini.local · In session
        #expect(activityRow(entry: entry("web-relay/web-relay-token", "in_session", repo: "dev", command: "scan"), machine: macMini)
            == ActivityRow(subject: "web-relay-token", outcome: "In session", tone: .normal, details: ["web-relay", "sealctl scan", "Devs-Mac-mini"]))
        #expect(activityRow(entry: entry("agent-lib-1.4.0/ubuntu-packages", "one_tap", kind: "secret"), machine: macMini)
            == ActivityRow(subject: "ubuntu-packages", outcome: "One tap", tone: .normal, details: ["agent-lib-1.4.0", "Devs-Mac-mini"]))
        #expect(activityRow(entry: entry("safe", "once", kind: "volume"), machine: macMini)
            == ActivityRow(subject: "Volume safe", outcome: "Allowed once", tone: .normal, details: ["Devs-Mac-mini"]))
        #expect(activityRow(entry: entry("seal", "confirmed", kind: "machine", command: "seal volume safe 5D1E7B2A-94C3-4F60-8A1B-3C2D4E5F6071"), machine: macMini)
            == ActivityRow(subject: "Seal volume safe", outcome: "Confirmed", tone: .normal, details: ["Devs-Mac-mini"]))
        #expect(activityRow(entry: entry("secrets a7c3e9f1-2b4d-4e6f-8a0c-1d3e5f7a9b42", "confirmed", command: "sealctl unseal",
                                         machine: "Zq7Lr2Xaq0r1s2t3u4v5w6x7y8z9A0B1C2D3E4F5G6H"), machine: nil)
            == ActivityRow(subject: "Secret store a7c3…42", outcome: "Confirmed", tone: .normal, details: ["sealctl unseal", "unpaired (Zq7Lr2Xa)"]))
    }

    @Test func outcomesAndNickname() {
        var nick = macMini
        nick.nickname = "Work laptop"
        let denied = activityRow(entry: entry("r2:acme-backups", "denied", kind: "backup"), machine: nick)
        #expect(denied.subject == "Backup r2:acme-backups")
        #expect(denied.tone == .declined)
        #expect(denied.details == ["Work laptop"])
        #expect(activityRow(entry: entry("github", "expired", kind: "ssh"), machine: macMini).tone == .muted)
    }

    @Test func oneLabelPerRow() {
        let row = ActivityRow(subject: "web-relay-token", outcome: "In session", tone: .normal, details: ["web-relay", "sealctl scan", "Devs-Mac-mini"])
        #expect(Texts.activityDetails(row) == "web-relay · sealctl scan · Devs-Mac-mini")
        #expect(Texts.activityLabel("09:18", row) == "09:18, web-relay-token, In session, web-relay, sealctl scan, Devs-Mac-mini")
        #expect(Texts.activityLabel("08:54", ActivityRow(subject: "Volume safe", outcome: "Allowed once", tone: .normal, details: [])) == "08:54, Volume safe, Allowed once")
    }
}
