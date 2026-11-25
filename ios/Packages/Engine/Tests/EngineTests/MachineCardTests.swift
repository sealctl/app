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
}
