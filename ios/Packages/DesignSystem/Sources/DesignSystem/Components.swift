import SwiftUI

// MARK: text

extension Text {
    /// The app's copy marks commands with backticks. Text can also carry what a machine sent
    /// (names, agents, repositories), so Markdown is applied only when all it does is draw
    /// code spans: links, emphasis, escapes and entities would hide or change characters, and
    /// such text is drawn as it is.
    public init(inlineMarkdown text: String) {
        if let a = Text.codeSpansOnly(text) { self.init(a) } else { self.init(verbatim: text) }
    }

    /// The parsed text when it shows every character of `text` except the backticks, with no
    /// link; otherwise nil.
    static func codeSpansOnly(_ text: String) -> AttributedString? {
        guard text.contains("`") else { return nil }
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        guard let a = try? AttributedString(markdown: text, options: options) else { return nil }
        guard String(a.characters) == text.replacingOccurrences(of: "`", with: "") else { return nil }
        guard !a.runs.contains(where: { $0.link != nil }) else { return nil }
        return a
    }
}

public struct TitleText: View {
    let text: String
    public init(_ text: String) { self.text = text }
    public var body: some View {
        Text(text).font(.title2.weight(.semibold)).foregroundStyle(Palette.ink)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityAddTraits(.isHeader)
    }
}

public struct BodyText: View {
    let text: String
    public init(_ text: String) { self.text = text }
    public var body: some View {
        Text(inlineMarkdown: text).font(.body).foregroundStyle(Palette.ink2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
    }
}

public struct MutedText: View {
    let text: String
    public init(_ text: String) { self.text = text }
    public var body: some View {
        Text(inlineMarkdown: text).font(.subheadline).foregroundStyle(Palette.muted)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// Machine names, key names, commands, paths, tags and fingerprints: monospace, never
/// translated, left to right.
public struct MonoText: View {
    let text: String
    let style: Font.TextStyle
    let weight: Font.Weight
    let color: Color
    public init(_ text: String, style: Font.TextStyle = .body, weight: Font.Weight = .regular, color: Color = Palette.ink) {
        self.text = text; self.style = style; self.weight = weight; self.color = color
    }
    public var body: some View {
        Text(verbatim: "\u{2066}\(text)\u{2069}").font(Fonts.mono(style, weight: weight)).foregroundStyle(color)
            .accessibilityLabel(Text(verbatim: text))
    }
}

public struct ErrorText: View {
    let text: String?
    public init(_ text: String?) { self.text = text }
    public var body: some View {
        if let text {
            Text(inlineMarkdown: text).font(.subheadline).foregroundStyle(Palette.accent)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("error")
        }
    }
}

public struct SectionLabel: View {
    let text: String
    public init(_ text: String) { self.text = text }
    public var body: some View {
        Text(text.uppercased()).font(.caption.weight(.semibold)).foregroundStyle(Palette.muted)
            .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 12)
            .accessibilityAddTraits(.isHeader)
    }
}

/// The wordmark `sealctl`: lower case, monospace, weight 600.
public struct Wordmark: View {
    let size: CGFloat
    public init(size: CGFloat = 28) { self.size = size }
    public var body: some View {
        Text(verbatim: "sealctl").font(.system(size: size, weight: .semibold, design: .monospaced))
            .foregroundStyle(Palette.ink)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityLabel("sealctl")
    }
}

// MARK: buttons

/// Filled with the accent.
public struct PrimaryButton: View {
    let title: String
    let enabled: Bool
    let action: () -> Void
    public init(_ title: String, enabled: Bool = true, action: @escaping () -> Void) {
        self.title = title; self.enabled = enabled; self.action = action
    }
    public var body: some View {
        Button(action: action) {
            Text(title).font(.body.weight(.semibold)).frame(maxWidth: .infinity, minHeight: 50)
                .foregroundStyle(Palette.onAccent)
                .background(Palette.accent.opacity(enabled ? 1 : 0.4), in: RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .accessibilityIdentifier(title)
    }
}

/// Outlined.
public struct SecondaryButton: View {
    let title: String
    let enabled: Bool
    let action: () -> Void
    public init(_ title: String, enabled: Bool = true, action: @escaping () -> Void) {
        self.title = title; self.enabled = enabled; self.action = action
    }
    public var body: some View {
        Button(action: action) {
            Text(title).font(.body.weight(.medium)).frame(maxWidth: .infinity, minHeight: 48)
                .foregroundStyle(enabled ? Palette.ink : Palette.muted)
                .background(Palette.surface, in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Palette.border, lineWidth: 1.5))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .accessibilityIdentifier(title)
    }
}

/// A plain text button (Deny, Not now, Cancel).
public struct PlainButton: View {
    let title: String
    let color: Color
    let action: () -> Void
    public init(_ title: String, color: Color = Palette.ink2, action: @escaping () -> Void) {
        self.title = title; self.color = color; self.action = action
    }
    public var body: some View {
        Button(action: action) {
            Text(title).font(.body).foregroundStyle(color).frame(maxWidth: .infinity, minHeight: 44)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(title)
    }
}

/// A text button inside a row or banner (Remove, Cancel, Show): accent text with at least a
/// 44-point touch target (SPEC.md 12), so a tap near its edge still lands.
public struct TextButton: View {
    let title: String
    let action: () -> Void
    public init(_ title: String, action: @escaping () -> Void) { self.title = title; self.action = action }
    public var body: some View {
        Button(action: action) {
            Text(title).font(.body).foregroundStyle(Palette.accent)
                .padding(.horizontal, 8)
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(title)
    }
}

/// One answer of the 3-of-4 card check, in monospace.
public struct ChoiceButton: View {
    let title: String
    let action: () -> Void
    public init(_ title: String, action: @escaping () -> Void) { self.title = title; self.action = action }
    public var body: some View {
        Button(action: action) {
            Text(verbatim: title).font(Fonts.mono(.title3)).foregroundStyle(Palette.ink)
                .frame(maxWidth: .infinity, minHeight: 52)
                .background(Palette.surface, in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Palette.border, lineWidth: 1.5))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("choice \(title)")
    }
}

// MARK: containers

/// A card with 12-point corners and a soft shadow.
public struct SurfaceCard<Content: View>: View {
    let content: Content
    public init(@ViewBuilder _ content: () -> Content) { self.content = content() }
    public var body: some View {
        VStack(alignment: .leading, spacing: 6) { content }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Palette.surface, in: RoundedRectangle(cornerRadius: 12))
            .shadow(color: .black.opacity(0.06), radius: 6, y: 2)
    }
}

public struct Banner<Trailing: View>: View {
    let text: String
    let tone: Color
    let trailing: Trailing
    public init(_ text: String, tone: Color = Palette.surface2, @ViewBuilder trailing: () -> Trailing) {
        self.text = text; self.tone = tone; self.trailing = trailing()
    }
    public var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(inlineMarkdown: text).font(.subheadline).foregroundStyle(Palette.ink)
                .fixedSize(horizontal: false, vertical: true)
            trailing
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tone, in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .combine)
    }
}

extension Banner where Trailing == EmptyView {
    public init(_ text: String, tone: Color = Palette.surface2) {
        self.init(text, tone: tone) { EmptyView() }
    }
}

/// "For npm test": label muted, value monospace.
public struct Fact: View {
    let label: String
    let value: String
    public init(_ label: String, _ value: String) { self.label = label; self.value = value }
    public var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label).font(.subheadline).foregroundStyle(Palette.muted).frame(width: 48, alignment: .leading)
            MonoText(value, style: .subheadline, color: Palette.ink)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
    }
}

public struct ToggleRow: View {
    let title: String
    @Binding var isOn: Bool
    let enabled: Bool
    public init(_ title: String, isOn: Binding<Bool>, enabled: Bool = true) {
        self.title = title; self._isOn = isOn; self.enabled = enabled
    }
    public var body: some View {
        Toggle(isOn: $isOn) {
            Text(title).font(.body.weight(.semibold)).foregroundStyle(Palette.ink)
        }
        .tint(Palette.accent)
        .disabled(!enabled)
        .accessibilityIdentifier(title)
    }
}

public struct NavRow: View {
    let title: String
    let value: String
    let action: () -> Void
    public init(_ title: String, value: String = "", action: @escaping () -> Void) {
        self.title = title; self.value = value; self.action = action
    }
    public var body: some View {
        Button(action: action) {
            HStack {
                Text(title).foregroundStyle(Palette.ink).multilineTextAlignment(.leading)
                Spacer()
                Text(value).foregroundStyle(Palette.muted)
                Image(systemName: "chevron.forward").foregroundStyle(Palette.muted).font(.footnote)
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(title)
    }
}

// MARK: states

public enum StatusKind: Sendable {
    case open, waiting, locked, unknown

    public var color: Color {
        switch self {
        case .open: return Palette.open
        case .waiting: return Palette.waiting
        case .locked, .unknown: return Palette.muted
        }
    }
}

/// The state dot; Waiting pulses unless Reduce Motion is on. Nothing else moves.
public struct StateDot: View {
    let kind: StatusKind
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulse = false
    public init(_ kind: StatusKind) { self.kind = kind }
    public var body: some View {
        Circle().fill(kind.color).frame(width: 9, height: 9)
            .opacity(kind == .waiting && pulse ? 0.35 : 1)
            .onAppear {
                guard kind == .waiting, !reduceMotion else { return }
                withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { pulse = true }
            }
            .accessibilityHidden(true)
    }
}

/// The state as a word with its dot: colour is never the only signal.
public struct StateLabel: View {
    let kind: StatusKind
    let text: String
    let spoken: String?
    public init(_ kind: StatusKind, _ text: String, spoken: String? = nil) {
        self.kind = kind; self.text = text; self.spoken = spoken
    }
    public var body: some View {
        HStack(spacing: 6) {
            StateDot(kind)
            Text(text).font(.subheadline.weight(.medium)).foregroundStyle(kind == .locked || kind == .unknown ? Palette.ink2 : kind.color)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spoken ?? text)
    }
}
