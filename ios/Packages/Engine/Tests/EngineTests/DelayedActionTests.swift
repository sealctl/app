import Foundation
import Testing
import EngineKit
@testable import Relay
import SealCore
@testable import Engine

/// How a delayed action is named on its screen, banner and push (SPEC.md 10.1, 11.23).
struct DelayedActionTests {
    let at: Int64 = 7_201_000

    /// Another install with the same words started showing the words: the relay's record has
    /// no machine and no kind, so it is named as started on another of your devices, never as
    /// leaving a computer.
    @Test func phoneOnlyRecordFromAnotherInstall() {
        let d = AppEngine.fromRelay(RelayDelayed(id: "d1", machine: nil, created: 1_000, releaseAt: at, expires: at + 900_000,
                                                 state: "waiting"))
        #expect(d.what == Texts.otherDevice)
        #expect(d.machine == nil)
        #expect(Texts.delayScreenTitle(d.what, name: nil) == "Started on another of your devices")
        #expect(Texts.delayWaiting(d.what, at: at)
            == "Showing your words, deleting your relay data or leaving sealctl was started on another phone or tablet "
            + "with your words. It goes ahead at \(Texts.time(at)). Not you? Cancel it.")
        #expect(Texts.delayedAt(d.what, name: "This phone", at: at)
            == "A protected action started on another of your devices goes ahead at \(Texts.time(at)).")
        let note = Texts.delayedNote(d.what, at: at)
        #expect(note.title == "A protected action started on another of your devices")
        #expect(note.body == "It goes ahead at \(Texts.time(at)). Open sealctl to see it or cancel it.")
        #expect(Texts.delayCancelledHere(d.what) == "Cancelled. Nothing happened.")
        #expect(Texts.delayOver(d.what) == "The wait is over. The phone or tablet that started it can go ahead.")
        #expect(Texts.delayGone(d.what).hasPrefix("This is no longer waiting"))
    }

    /// Another install approved `unseal --all` for a machine: still that machine's leaving.
    @Test func machineRecordFromAnotherInstall() {
        let d = AppEngine.fromRelay(RelayDelayed(id: "d2", machine: "m1", created: 1_000, releaseAt: at, expires: at + 900_000,
                                                 state: "waiting"))
        #expect(d.what == "unseal_all")
        #expect(Texts.delayScreenTitle(d.what, name: "dev@mbp.example.com") == "Leaving sealctl on dev@mbp.example.com")
        #expect(Texts.delayScreenTitle(d.what, name: nil) == "Leaving sealctl on this computer")
        #expect(Texts.delayWaiting(d.what, at: at) == Texts.delayBody)
        #expect(Texts.delayedAt(d.what, name: "dev@mbp.example.com", at: at) == Texts.handsBackAt("dev@mbp.example.com", at: at))
        #expect(Texts.delayedNote(d.what, at: at) == (Texts.delayedTitle, Texts.delayedBody))
        #expect(Texts.delayCancelledHere(d.what) == Texts.cancelledHere)
        #expect(Texts.delayOver(d.what) == "The hour is over. The computer goes ahead.")
    }

    /// The actions this install starts keep their own titles.
    @Test func actionsOnThisPhone() {
        #expect(Texts.delayScreenTitle("words", name: nil) == "Showing your words")
        #expect(Texts.delayScreenTitle("delete", name: nil) == "Deleting your relay data")
        #expect(Texts.delayScreenTitle("leave", name: nil) == "Leaving sealctl")
        #expect(Texts.delayWaiting("words", at: at) == Texts.delayBody)
        #expect(Texts.delayedNote("words", at: at) == (Texts.delayedTitle, Texts.delayedBody))
        #expect(Texts.delayedNote(nil, at: at) == (Texts.delayedTitle, Texts.delayedBody))
        #expect(Texts.delayGone("words") == "This waited too long. Start again.")
    }
}
