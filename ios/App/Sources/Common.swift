import DesignSystem
import Engine
import EngineKit
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// A screen: a bar with a back button and title, scrolling content, and buttons pinned at
/// the bottom.
struct Page<Content: View, Bottom: View>: View {
    let title: String?
    let onBack: (() -> Void)?
    let content: Content
    let bottom: Bottom

    init(_ title: String? = nil, onBack: (() -> Void)?, @ViewBuilder content: () -> Content,
         @ViewBuilder bottom: () -> Bottom) {
        self.title = title
        self.onBack = onBack
        self.content = content()
        self.bottom = bottom()
    }

    var body: some View {
        VStack(spacing: 0) {
            if onBack != nil || title != nil {
                HStack(spacing: 4) {
                    if let onBack {
                        Button(action: onBack) {
                            Image(systemName: "chevron.backward").font(.title3.weight(.semibold))
                                .foregroundStyle(Palette.ink).frame(width: 44, height: 44)
                        }
                        .accessibilityLabel("Back")
                        .accessibilityIdentifier("Back")
                    } else {
                        Spacer().frame(width: 16)
                    }
                    if let title {
                        Text(title).font(.title3.weight(.semibold)).foregroundStyle(Palette.ink)
                            .accessibilityAddTraits(.isHeader)
                    }
                    Spacer()
                }
                .padding(.horizontal, 4)
                .frame(minHeight: 52)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 12) { content }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 8)
            }
            .scrollDismissesKeyboard(.interactively)
            VStack(spacing: 8) { bottom }
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
        }
        .background(Palette.paper.ignoresSafeArea())
    }
}

extension Page where Bottom == EmptyView {
    init(_ title: String? = nil, onBack: (() -> Void)?, @ViewBuilder content: () -> Content) {
        self.init(title, onBack: onBack, content: content, bottom: { EmptyView() })
    }
}

struct Gap: View {
    let h: CGFloat
    init(_ h: CGFloat = 8) { self.h = h }
    var body: some View { Spacer().frame(height: h) }
}

@MainActor
enum Links {
    static func open(_ s: String) {
        #if canImport(UIKit)
        if let u = URL(string: s) { UIApplication.shared.open(u) }
        #endif
    }

    static func settings() {
        #if canImport(UIKit)
        open(UIApplication.openSettingsURLString)
        #endif
    }

    static func notificationSettings() {
        #if canImport(UIKit)
        open(UIApplication.openNotificationSettingsURLString)
        #endif
    }
}

/// A success or a warning haptic: confirms Allow and Deny; nothing depends on it.
@MainActor
func haptic(_ success: Bool) {
    #if canImport(UIKit)
    UINotificationFeedbackGenerator().notificationOccurred(success ? .success : .warning)
    #endif
}

/// Every second, for countdowns and "WAITING · 0:12".
struct Ticker<Content: View>: View {
    let content: (Int64) -> Content
    init(@ViewBuilder _ content: @escaping (Int64) -> Content) { self.content = content }
    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            content(Int64(ctx.date.timeIntervalSince1970 * 1000))
        }
    }
}

extension MachineState {
    var kind: StatusKind {
        switch self {
        case .open: return .open
        case .waiting: return .waiting
        case .locked: return .locked
        case .unknown: return .unknown
        }
    }
}

/// Machine-supplied text, sanitised and capped (11.7).
func shown(_ text: String, _ max: Int = Texts.maxName) -> String { Texts.shown(text, max) }

func purposeName(_ p: String) -> String {
    switch p {
    case "secrets": return "Secret store"
    case "secret": return "Own-approval secret"
    case "volume": return "Volume"
    case "backup": return "Backup"
    default: return p
    }
}

func planLabel(_ kind: String) -> String {
    switch kind {
    case "ai": return "AI tools"
    case "local": return "local files"
    default: return kind
    }
}
