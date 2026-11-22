import SwiftUI
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

/// Brand tokens (SPEC.md 11.1, `brand/`): light and dark follow the system.
public enum Palette {
    public static let paper = Color(light: 0xFFFFFF, dark: 0x0E121A)
    public static let surface = Color(light: 0xF6F7F9, dark: 0x151A24)
    public static let surface2 = Color(light: 0xEEF0F4, dark: 0x1B2130)
    public static let ink = Color(light: 0x1A2133, dark: 0xEEF0F5)
    public static let ink2 = Color(light: 0x3E4659, dark: 0xC8CDD9)
    public static let muted = Color(light: 0x5F6677, dark: 0x949BAD)
    public static let border = Color(light: 0xE3E6EC, dark: 0x242B3A)
    public static let accent = Color(light: 0xB4232C, dark: 0xFF5C63)
    public static let accentSoft = Color(light: 0xF8E3E5, dark: 0x3B2327)
    public static let onAccent = Color(light: 0xFFFFFF, dark: 0x12151C)
    /// Status colours are separate from the accent; every status also has its word.
    public static let open = Color(light: 0x157F3C, dark: 0x4CC47C)
    public static let waiting = Color(light: 0xB45309, dark: 0xF0A54A)
}

extension Color {
    public init(light: UInt32, dark: UInt32) {
        #if canImport(UIKit)
        self.init(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(hex: dark) : UIColor(hex: light) })
        #else
        self.init(nsColor: NSColor(name: nil) { a in
            a.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(hex: dark) : NSColor(hex: light)
        })
        #endif
    }
}

#if canImport(UIKit)
extension UIColor {
    convenience init(hex: UInt32) {
        self.init(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
}
#else
extension NSColor {
    convenience init(hex: UInt32) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
}
#endif

/// Text in the system sans; names, keys, commands, paths, tags, the fingerprint and the
/// wordmark in the system monospace. No bundled fonts.
public enum Fonts {
    public static func mono(_ style: Font.TextStyle = .body, weight: Font.Weight = .regular) -> Font {
        .system(style, design: .monospaced).weight(weight)
    }
}
