import Testing
@testable import Engine
import EngineKit
import SealCore

/// The machine card on the Machines list (SPEC.md 11.17), through the shared crate as the screen gets it.
struct MachineCardTests {
    let now: Int64 = 1_800_000_000_000
    let hour: Int64 = 3_600_000
    var macMini: Machine {
        Machine(key: String(repeating: "A", count: 43), boxKey: "", name: "dev@Devs-Mac-mini.local", os: "macOS 26.1",
                model: "Mac16,10", hint: nil, pairedAt: 0, nickname: nil, lastSeen: UInt64(now - hour), lastStatus: nil,
                tagShown: false, flagged: false, relay: "", updated: 0, deleted: false)
    }

    func card(_ m: Machine, row: String = "Locked · last report 1 h ago") -> MachineView {
        MachineView(machine: m, name: machineShortName(machine: m), state: .locked, row: row, detail: "", leftSecs: nil)
    }

    @Test func shortNameAndModel() {
        #expect(machineShortName(machine: macMini) == "Devs-Mac-mini")
        var nick = macMini
        nick.nickname = "Work laptop"
        #expect(machineShortName(machine: nick) == "Work laptop")
        var plain = macMini
        plain.name = "dev@mbp.example.com"
        #expect(machineShortName(machine: plain) == "mbp.example.com")
        #expect(machineModelName(model: "Mac16,10") == "Mac mini")
        #expect(machineModelName(model: "MacBookPro18,3") == "MacBook Pro")
        #expect(machineModelName(model: "ThinkPad X1 Carbon Gen 11") == "ThinkPad X1 Carbon Gen 11")
    }

    @Test func threeLinesAndOneLabel() {
        let v = card(macMini)
        #expect(v.name == "Devs-Mac-mini")
        #expect(v.sub(now: now) == "Mac mini · seen 1 h ago")
        #expect(v.unseen(now: now) == nil)
        #expect(v.label(now: now) == "Devs-Mac-mini, Locked · last report 1 h ago, Mac mini, seen 1 h ago")
    }

    @Test func noModelAndLongUnseen() {
        var m = macMini
        m.model = nil
        m.flagged = true
        m.lastSeen = UInt64(now - 94 * 24 * hour)
        let v = card(m, row: "Locked")
        #expect(v.sub(now: now) == "seen 94 days ago")
        #expect(v.unseen(now: now) == "Not seen for 94 days")
        #expect(v.label(now: now) == "Devs-Mac-mini, Locked, seen 94 days ago, Not seen for 94 days")
        var empty = macMini
        empty.model = ""
        #expect(card(empty).model == nil)
    }

    let min: Int64 = 60_000

    /// An Open status reported at `now`: `left` seconds left, idle `idle` seconds, allowance `allow`.
    func open(_ left: UInt64, idle: UInt64?, allow: UInt64?, stop: Int64? = nil) -> MachineSession {
        machineSession(status: SessionStatus(session: "open", left: left, idle: idle, allow: allow, stop: stop.map { UInt64($0) },
                                             place: nil, reportedAt: UInt64(now), seq: 1))
    }

    @Test func activeWhileTheMachineWorks() {
        let s = open(14_390, idle: 10, allow: 14_400)
        // no countdown: the same row a second, a minute and two minutes later
        for later in [0, 1_000, min, 2 * min] {
            #expect(MachineView.openRow(s, now: now + later) == "Open · active")
        }
        #expect(MachineView.spokenOpenRow(s, now: now) == "Open, active")
        // no status 3 minutes after its last work: idle, counted from that work
        #expect(!MachineView.isActive(s, now: now + 170_000))
        #expect(MachineView.openRow(s, now: now + 170_000) == "Open · idle 3 min · locks at \(Texts.time(now + 14_390_000))")
    }

    @Test func idleWithTheTimeItLocks() {
        let s = open(13_680, idle: 720, allow: 14_400, stop: now + 10 * 60 * min)
        let at = Texts.time(now + 13_680_000)
        #expect(MachineView.openRow(s, now: now) == "Open · idle 12 min · locks at \(at)")
        #expect(MachineView.openRow(s, now: now + 5 * min) == "Open · idle 17 min · locks at \(at)")
        #expect(MachineView.spokenOpenRow(s, now: now) == "Open, idle \(Texts.spokenDuration(720)), locks at \(at)")
        // the hard stop first when it is sooner
        let stop = now + 30 * min
        #expect(MachineView.openRow(open(13_680, idle: 720, allow: 14_400, stop: stop), now: now)
            == "Open · idle 12 min · locks at \(Texts.time(stop))")
        // past the time it locks: not Open
        #expect(MachineView.openRow(open(600, idle: 3_000, allow: 3_600), now: now + 10 * min) == nil)
    }

    @Test func aCliWithoutIdleTimeCountsDown() {
        let s = open(600, idle: nil, allow: nil)
        #expect(MachineView.openRow(s, now: now) == "Open · 10 min left")
        #expect(MachineView.openRow(s, now: now + min) == "Open · 9 min left")
        #expect(MachineView.openRow(s, now: now + 10 * min) == nil)
    }
}
