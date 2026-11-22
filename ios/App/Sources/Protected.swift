import DesignSystem
import Engine
import SealCore
import SwiftUI
import UIKit

/// Protecting the words on screen (SPEC.md 11.21): the content is drawn inside the layer of a
/// secure `UITextField`, which the system leaves out of screenshots and recordings; while the
/// screen is recorded or mirrored the words are replaced; the app switcher gets a cover.
struct Protected<Content: View>: View {
    @Environment(Router.self) private var router
    @SwiftUI.State private var captured = UIScreen.main.isCaptured
    let content: Content

    init(@ViewBuilder _ content: () -> Content) { self.content = content() }

    var body: some View {
        Group {
            if captured {
                BodyText("Hidden while the screen is recorded or mirrored.")
                    .frame(maxWidth: .infinity, minHeight: 120)
            } else {
                SecureLayer { content }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIScreen.capturedDidChangeNotification)) { _ in
            captured = UIScreen.main.isCaptured
        }
        .onAppear { router.secure += 1 }
        .onDisappear { router.secure -= 1 }
        .overlay(alignment: .bottom) {
            if router.screenshotNote {
                Text("The screenshot doesn't show your words.").font(.footnote).padding(10)
                    .background(Palette.surface2, in: Capsule())
                    .task {
                        try? await Task.sleep(for: .seconds(3))
                        router.screenshotNote = false
                    }
            }
        }
    }
}

/// Marks a screen whose typed words must not leave the phone: the app switcher cover.
struct SecureScreen: ViewModifier {
    @Environment(Router.self) private var router
    func body(content: Content) -> some View {
        content
            .onAppear { router.secure += 1 }
            .onDisappear { router.secure -= 1 }
    }
}

extension View {
    func secureScreen() -> some View { modifier(SecureScreen()) }
}

/// Hosts SwiftUI content inside a secure text field's canvas.
struct SecureLayer<Content: View>: UIViewRepresentable {
    let content: Content
    init(@ViewBuilder _ content: () -> Content) { self.content = content() }

    func makeUIView(context: Context) -> UIView {
        let host = UIHostingController(rootView: content)
        host.view.backgroundColor = .clear
        host.view.translatesAutoresizingMaskIntoConstraints = false
        context.coordinator.host = host
        let field = UITextField()
        field.isSecureTextEntry = true
        field.isUserInteractionEnabled = false
        let canvas = field.subviews.first ?? UIView()
        canvas.subviews.forEach { $0.removeFromSuperview() }
        canvas.isUserInteractionEnabled = true
        canvas.translatesAutoresizingMaskIntoConstraints = false
        canvas.addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.topAnchor.constraint(equalTo: canvas.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: canvas.bottomAnchor),
            host.view.leadingAnchor.constraint(equalTo: canvas.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: canvas.trailingAnchor),
        ])
        return canvas
    }

    func updateUIView(_ view: UIView, context: Context) {
        context.coordinator.host?.rootView = content
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UIView, context: Context) -> CGSize? {
        guard let host = context.coordinator.host else { return nil }
        let width = proposal.width ?? UIView.layoutFittingExpandedSize.width
        return host.sizeThatFits(in: CGSize(width: width, height: UIView.layoutFittingExpandedSize.height))
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var host: UIHostingController<Content>?
    }
}

/// One word: "Word 7: ocean", the first four letters bold, in large monospace. VoiceOver can
/// spell it letter by letter with the rotor's spelling action; nothing can be copied.
struct WordRow: View {
    let number: Int
    let word: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(verbatim: "\(number)").font(Fonts.mono(.title3)).foregroundStyle(Palette.muted).frame(width: 36, alignment: .trailing)
            (Text(verbatim: String(word.prefix(4))).bold() + Text(verbatim: String(word.dropFirst(4))))
                .font(.system(.title, design: .monospaced))
                .foregroundStyle(Palette.ink)
        }
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Word \(number): \(word)")
        .accessibilityIdentifier("word-\(number)")
        .accessibilityValue(word)
        .textSelection(.disabled)
    }
}

// MARK: the word keypad (11.4)

/// Letters a to z and delete, so no system keyboard sees the words. Letters that cannot
/// continue a BIP39 word are disabled; four letters that name a word complete it.
struct WordKeypad: View {
    let prefix: String
    let onChange: (String) -> Void
    let onWord: (String) -> Void

    private let rows = ["qwertyuiop", "asdfghjkl", "zxcvbnm"]

    var body: some View {
        let entry = wordEntry(prefix: prefix)
        VStack(spacing: 6) {
            ForEach(rows, id: \.self) { row in
                HStack(spacing: 4) {
                    ForEach(Array(row), id: \.self) { c in
                        let letter = String(c)
                        key(letter, enabled: entry.nextLetters.contains(letter)) { tap(letter) }
                    }
                }
            }
            HStack(spacing: 8) {
                key("delete", enabled: !prefix.isEmpty) { onChange(String(prefix.dropLast())) }
                key(entry.exact ? "✓ \(prefix)" : "✓", enabled: entry.exact || entry.completed != nil, id: "key done") {
                    onWord(entry.exact ? prefix : entry.completed ?? prefix)
                }
            }
        }
    }

    private func tap(_ c: String) {
        let next = prefix + c
        let e = wordEntry(prefix: next)
        if let done = e.completed, next.count >= 4 || done == next {
            onWord(done)
        } else {
            onChange(next)
        }
    }

    private func key(_ label: String, enabled: Bool, id: String? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(verbatim: label).font(Fonts.mono(.title3, weight: .medium))
                .foregroundStyle(enabled ? Palette.ink : Palette.muted.opacity(0.4))
                .frame(maxWidth: .infinity, minHeight: 44)
                .background(enabled ? Palette.surface : Palette.surface2, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Palette.border, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .accessibilityLabel("key \(label)")
        .accessibilityIdentifier(id ?? "key \(label)")
    }
}

/// One numbered field of typed words.
struct WordField: View {
    let number: Int
    let value: String
    let focused: Bool
    let error: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack {
                Text(verbatim: "\(number)").font(Fonts.mono(.subheadline)).foregroundStyle(Palette.muted).frame(width: 32, alignment: .leading)
                Text(verbatim: value.isEmpty ? "____" : value).font(Fonts.mono(.title3, weight: .medium)).foregroundStyle(Palette.ink)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(focused ? Palette.accentSoft : Palette.surface, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(error ? Palette.accent : Palette.border, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Word \(number)")
        .accessibilityValue(value)
        .accessibilityIdentifier("field-\(number)")
    }
}
