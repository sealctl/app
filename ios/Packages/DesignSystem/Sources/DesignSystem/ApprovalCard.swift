import SwiftUI

/// What the approval card shows (SPEC.md 11.7), as plain values.
public struct ApprovalCardModel: Equatable {
    public enum Style: Equatable { case primary, secondary, plain }

    public struct ButtonModel: Equatable, Identifiable {
        public let id: String
        public let title: String
        public let style: Style
        public init(id: String, title: String, style: Style) { self.id = id; self.title = title; self.style = style }
    }

    public var stateLine: String
    public var expired: Bool
    public var title: String
    /// The part of the title in monospace and the accent colour.
    public var subject: String?
    public var facts: [Pair]
    public var note: String?
    public var agentNote: String?
    public var buttons: [ButtonModel]
    public var more: String?
    public var footer: String?
    public var stopped: String?

    public struct Pair: Equatable, Hashable {
        public let label: String
        public let value: String
        public init(_ label: String, _ value: String) { self.label = label; self.value = value }
    }

    public init(stateLine: String, expired: Bool, title: String, subject: String?, facts: [Pair], note: String?,
                agentNote: String?, buttons: [ButtonModel], more: String?, footer: String?, stopped: String?) {
        self.stateLine = stateLine; self.expired = expired; self.title = title; self.subject = subject
        self.facts = facts; self.note = note; self.agentNote = agentNote; self.buttons = buttons
        self.more = more; self.footer = footer; self.stopped = stopped
    }
}

/// The approval card: state, title, facts, then the buttons pinned at the bottom while the
/// rest scrolls at large text sizes. VoiceOver reads state, title, facts, buttons.
public struct ApprovalCardView: View {
    let model: ApprovalCardModel
    let busy: Bool
    let onButton: (String) -> Void
    let onClose: () -> Void

    public init(model: ApprovalCardModel, busy: Bool, onButton: @escaping (String) -> Void, onClose: @escaping () -> Void) {
        self.model = model; self.busy = busy; self.onButton = onButton; self.onClose = onClose
    }

    private var titleText: Text {
        guard let s = model.subject, let r = model.title.range(of: s) else {
            return Text(verbatim: model.title)
        }
        let before = String(model.title[..<r.lowerBound])
        let after = String(model.title[r.upperBound...])
        return Text(verbatim: before)
            + Text(verbatim: s).font(.system(.title2, design: .monospaced).weight(.semibold)).foregroundColor(Palette.accent)
            + Text(verbatim: after)
    }

    public var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 8) {
                        StateDot(model.expired ? .locked : .waiting)
                        Text(model.stateLine).font(.footnote.weight(.semibold))
                            .foregroundStyle(model.expired ? Palette.muted : Palette.waiting)
                    }
                    .accessibilityElement(children: .combine)
                    titleText.font(.title2.weight(.semibold)).foregroundStyle(Palette.ink)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityLabel(model.title)
                        .accessibilityAddTraits(.isHeader)
                        .accessibilityIdentifier("card-title")
                    ForEach(model.facts, id: \.self) { Fact($0.label, $0.value) }
                    if let note = model.note { MutedText(note) }
                    if let a = model.agentNote { MutedText(a) }
                    if let stopped = model.stopped { BodyText(stopped) }
                }
                .padding(.horizontal, 20)
                .padding(.top, 24)
            }
            VStack(spacing: 8) {
                if model.stopped != nil {
                    SecondaryButton("Close", action: onClose)
                } else {
                    ForEach(model.buttons) { b in
                        switch b.style {
                        case .primary: PrimaryButton(b.title, enabled: !busy) { onButton(b.id) }
                        case .secondary: SecondaryButton(b.title, enabled: !busy) { onButton(b.id) }
                        case .plain: PlainButton(b.title) { if !busy { onButton(b.id) } }
                        }
                    }
                    if let more = model.more { MutedText(more) }
                    if let footer = model.footer { MutedText(footer) }
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .background(Palette.surface)
    }
}
