import ShidouMarkdown
import SwiftUI

/// One token palette for every surface that renders code — transcript fences
/// and the file reader both.
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
            return dark
                ? Color(red: 0.85, green: 0.60, blue: 0.95)
                : Color(red: 0.50, green: 0.16, blue: 0.62)
        case .string:
            return dark
                ? Color(red: 0.62, green: 0.84, blue: 0.55)
                : Color(red: 0.13, green: 0.45, blue: 0.16)
        case .number:
            return dark
                ? Color(red: 0.95, green: 0.72, blue: 0.44)
                : Color(red: 0.63, green: 0.36, blue: 0.05)
        case .comment:
            return .secondary
        case .type:
            return dark
                ? Color(red: 0.50, green: 0.78, blue: 0.95)
                : Color(red: 0.09, green: 0.39, blue: 0.63)
        case .punctuation:
            return .secondary
        }
    }
}
