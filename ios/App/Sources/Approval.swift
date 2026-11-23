import DesignSystem
import Engine
import EngineKit
import SealCore
import SwiftUI
import UIKit

/// The approval card as a sheet (SPEC.md 11.7): the oldest waiting request first, or the one
/// a notification tap asked for.
struct ApprovalSheet: View {
    @Environment(AppModel.self) private var model
    @SwiftUI.State private var busy = false

    var body: some View {
        let e = model.engine!
        let list = e.waiting.filter { $0.verdict.asking == .oneTap }
        if let w = list.first(where: { $0.id == e.focusRequest }) ?? list.min(by: { $0.seenAt < $1.seenAt }) {
            Ticker { now in
                ApprovalCardView(model: cardModel(w, e, more: list.count - 1, now: now), busy: busy, onButton: { id in
                    answer(w, id, e)
                }, onClose: { e.dismiss(w.id) })
            }
            .id(w.id)
        }
    }

    private func answer(_ w: Waiting, _ id: String, _ e: AppEngine) {
        guard !busy, let option = w.verdict.options.first(where: { Texts.actionId($0) == id }) else { return }
        busy = true
        Task {
            if await e.answer(w.id, option) { haptic(option != .deny) }
            e.focusRequest = nil
            busy = false
        }
    }

    private func cardModel(_ w: Waiting, _ e: AppEngine, more: Int, now: Int64) -> ApprovalCardModel {
        let name = e.displayName(w.machine)
        let f = Texts.facts(w, machineName: name)
        var facts: [ApprovalCardModel.Pair] = []
        if let c = f.command { facts.append(.init("For", c)) }
        if let d = f.cwd { facts.append(.init("In", d)) }
        facts.append(.init("From", [name, f.agent].compactMap { $0 }.joined(separator: " · ")))
        let secs = (now - min(w.relay.created, now)) / 1000
        let buttons = w.verdict.options.enumerated().map { i, o in
            ApprovalCardModel.ButtonModel(id: Texts.actionId(o), title: Texts.button(o, biometry: e.biometryName),
                                          style: o == .deny ? .plain : (i == 0 ? .primary : .secondary))
        }
        var footer: String?
        if w.verdict.answersByItselfHere, let place = e.currentPlaceName { footer = Texts.answersHere(place) }
        return ApprovalCardModel(
            stateLine: Texts.waitingFor(secs), expired: w.expired, title: Texts.title(f), subject: Texts.titleSubject(f),
            facts: facts, note: Texts.note(w),
            agentNote: w.verdict.agentFirstUse && !e.local.agentNoteShown ? Texts.agentNote : nil,
            buttons: buttons, more: more > 0 ? Texts.moreWaiting(more) : nil, footer: footer,
            stopped: w.expired ? Texts.stoppedWaiting(name) : nil)
    }
}
