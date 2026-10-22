import AppKit
import SwiftUI

/// Design tokens. Colours lean on macOS semantic colours so the app follows
/// light and dark appearance; only the brand accent and status hues are fixed.
enum Theme {
    // MARK: Brand and status

    /// Periwinkle accent used for selection, icons, links, and chips.
    static let accent = Color(red: 0x5C / 255, green: 0x79 / 255, blue: 0xF5 / 255)
    static let success = Color(nsColor: .dynamic(light: 0x34A853, dark: 0x8FD27A))
    static let warning = Color(nsColor: .dynamic(light: 0xC77700, dark: 0xF2B44B))
    static let danger = Color(nsColor: .dynamic(light: 0xD93B30, dark: 0xF0695E))

    // MARK: Surfaces

    /// Main content background (dark: #1E1E1E).
    static let contentBackground = Color(nsColor: .controlBackgroundColor)
    /// Card fill: a hair lighter than the page.
    static let cardFill = Color.primary.opacity(0.012)
    /// Card outline.
    static let cardStroke = Color.primary.opacity(0.06)
    /// Raised tiles and rows inside cards (dark: #282828).
    static let tileFill = Color.primary.opacity(0.04)
    static let tileFillHover = Color.primary.opacity(0.07)
    static let tileFillPressed = Color.primary.opacity(0.10)
    static let tileStroke = Color.primary.opacity(0.05)
    /// Hairline separators inside cards.
    static let separator = Color.primary.opacity(0.08)
    /// Filled neutral button (dark: #565656).
    static let neutralButtonFill = Color(nsColor: .dynamicAlpha(light: (0x000000, 0.08), dark: (0xFFFFFF, 0.26)))
    static let neutralButtonFillPressed = Color(nsColor: .dynamicAlpha(light: (0x000000, 0.14), dark: (0xFFFFFF, 0.34)))
    /// Key-cap fill and outline.
    static let keyCapFill = Color.primary.opacity(0.03)
    static let keyCapStroke = Color.primary.opacity(0.12)
    /// Accent-tinted fills for icon discs and chips.
    static let accentSoft = accent.opacity(0.16)
    static let accentSofter = accent.opacity(0.10)

    // MARK: Text

    static let textPrimary = Color.primary.opacity(0.86)
    static let textSecondary = Color(nsColor: .labelColor).opacity(0.7)
    /// Small descriptions carry essential instructions, including legacy tertiary uses.
    static let textTertiary = textSecondary

    // MARK: Metrics

    static let sidebarWidth: CGFloat = 220
    static let pagePadding: CGFloat = 24
    static let pageTopPadding: CGFloat = 74
    static let cardRadius: CGFloat = 10
    static let tileRadius: CGFloat = 8
    static let cardPadding: CGFloat = 16
    static let sectionSpacing: CGFloat = 22

    // MARK: Type

    enum Font {
        static let pageTitle = SwiftUI.Font.system(size: 30, weight: .bold)
        static let pageSubtitle = SwiftUI.Font.system(size: 14.5)
        static let sectionTitle = SwiftUI.Font.system(size: 13, weight: .semibold)
        static let sectionCaption = SwiftUI.Font.system(size: 11)
        static let rowTitle = SwiftUI.Font.system(size: 13)
        static let rowTitleEmphasis = SwiftUI.Font.system(size: 13, weight: .semibold)
        static let rowSubtitle = SwiftUI.Font.system(size: 11)
        static let tileTitle = SwiftUI.Font.system(size: 13, weight: .semibold)
        static let tileSubtitle = SwiftUI.Font.system(size: 10.5)
        static let keyCap = SwiftUI.Font.system(size: 10.5, weight: .semibold)
        static let mono = SwiftUI.Font.system(size: 12, design: .monospaced)
    }
}

extension NSColor {
    /// A colour that resolves to `light` in Aqua and `dark` in Dark Aqua.
    static func dynamic(light: UInt32, dark: UInt32) -> NSColor {
        NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return NSColor(hex: isDark ? dark : light)
        }
    }

    /// Like `dynamic(light:dark:)` with an alpha per appearance.
    static func dynamicAlpha(light: (UInt32, CGFloat), dark: (UInt32, CGFloat)) -> NSColor {
        NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let (hex, alpha) = isDark ? dark : light
            return NSColor(hex: hex, alpha: alpha)
        }
    }

    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: alpha
        )
    }
}

extension Color {
    /// Parses `#RRGGBB` or `RRGGBB`. Returns nil for anything else.
    init?(hexString: String) {
        var s = hexString.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let value = UInt32(s, radix: 16) else { return nil }
        self.init(nsColor: NSColor(hex: value))
    }

    /// `#RRGGBB` in sRGB, upper case.
    var hexString: String {
        let c = NSColor(self).usingColorSpace(.sRGB) ?? .black
        return String(
            format: "#%02X%02X%02X",
            Int((c.redComponent * 255).rounded()),
            Int((c.greenComponent * 255).rounded()),
            Int((c.blueComponent * 255).rounded())
        )
    }
}
