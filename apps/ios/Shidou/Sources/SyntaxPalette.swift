import ShidouMarkdown
import SwiftUI

/// One token palette for every surface that renders code — transcript fences
/// and the file reader both.
///
/// The values are Pierre's `pierre-dark` / `pierre-light` themes, which the
/// web client's `@pierre/diffs` surfaces use, so a file reads the same on the
/// phone as it does in the browser.
///
/// Colours carry emphasis, never meaning: the same code reads correctly with
/// every token plain, which is exactly what an unhighlighted block already is.
enum SyntaxPalette {
    static func color(for token: SyntaxToken, scheme: ColorScheme) -> Color {
        let dark = scheme == .dark
        switch token {
        case .plain:
            return .primary
        case .keyword:
            return dark ? Color(hex: 0xFF678D) : Color(hex: 0xD32A61)
        case .string:
            return dark ? Color(hex: 0x5ECC71) : Color(hex: 0x199F43)
        case .number:
            return dark ? Color(hex: 0x68CDF2) : Color(hex: 0x1CA1C7)
        case .comment:
            return Color(hex: 0x737373)
        case .type:
            return dark ? Color(hex: 0xD568EA) : Color(hex: 0xA631BE)
        case .punctuation:
            return dark ? Color(hex: 0x8C8C8C) : Color(hex: 0x636363)
        }
    }

    /// The diff accents `@pierre/diffs` draws additions and deletions with.
    static func addition(scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(hex: 0x5ECC71) : Color(hex: 0x0DBE4E)
    }

    static func deletion(scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(hex: 0xFF6762) : Color(hex: 0xFF2E3F)
    }

    /// The row wash behind a changed line: the web mixes 20% of the accent into
    /// the page in dark mode and 12% in light.
    static func lineWash(_ accent: Color, scheme: ColorScheme) -> Color {
        accent.opacity(scheme == .dark ? 0.2 : 0.12)
    }
}

extension Color {
    fileprivate init(hex: UInt32) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }
}
