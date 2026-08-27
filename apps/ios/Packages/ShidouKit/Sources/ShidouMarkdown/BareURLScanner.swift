import Foundation

/// Splits a plain run around bare `http(s)://…` spans, ported from the
/// desktop's `linkify_bare_urls` and `trimmed_bare_url_end`.
///
/// Hand-written rather than regex-backed: this runs on every streamed tail
/// parse, and the scan is a single pass over characters the parser has already
/// materialized.
enum BareURLScanner {
    /// Characters CommonMark would not carry into an autolink destination.
    private static let terminators: Set<Character> = [
        " ", "\t", "\n", "<", ">", "\"", "`", "\\",
    ]

    static func split(_ run: InlineRun) -> [InlineRun] {
        let characters = Array(run.text)
        guard characters.count > 8 else { return [run] }

        var out: [InlineRun] = []
        var plainStart = 0
        var index = 0
        while index < characters.count {
            guard let schemeEnd = schemeLength(characters, at: index) else {
                index += 1
                continue
            }
            var end = index + schemeEnd
            while end < characters.count, !terminators.contains(characters[end]) { end += 1 }
            end = trimmedEnd(characters, start: index, end: end)
            guard end > index + schemeEnd else {
                index += schemeEnd
                continue
            }
            if plainStart < index {
                out.append(
                    InlineRun(text: String(characters[plainStart..<index]), style: run.style)
                )
            }
            let url = String(characters[index..<end])
            var style = run.style
            style.link = url
            out.append(InlineRun(text: url, style: style))
            plainStart = end
            index = end
        }
        guard !out.isEmpty else { return [run] }
        if plainStart < characters.count {
            out.append(InlineRun(text: String(characters[plainStart...]), style: run.style))
        }
        return out
    }

    /// Length of `http://` or `https://` starting at `index`, and only on a
    /// word boundary so `xhttps://…` is not linkified.
    private static func schemeLength(_ characters: [Character], at index: Int) -> Int? {
        guard characters[index] == "h" || characters[index] == "H" else { return nil }
        if index > 0 {
            let previous = characters[index - 1]
            if previous.isLetter || previous.isNumber { return nil }
        }
        for candidate in ["https://", "http://"] {
            let length = candidate.count
            guard index + length <= characters.count else { continue }
            let slice = String(characters[index..<(index + length)]).lowercased()
            if slice == candidate { return length }
        }
        return nil
    }

    /// Sentence punctuation and unmatched closing delimiters are prose around
    /// a URL, not part of it. Balanced delimiters stay, as in a Wikipedia path
    /// ending in `(disambiguation)`.
    private static func trimmedEnd(_ characters: [Character], start: Int, end: Int) -> Int {
        var end = end
        var parens = balance(characters[start..<end], "(", ")")
        var brackets = balance(characters[start..<end], "[", "]")
        var braces = balance(characters[start..<end], "{", "}")
        while end > start {
            let last = characters[end - 1]
            let trim: Bool
            switch last {
            case ".", ",", ":", ";", "?", "!", "'":
                trim = true
            case ")" where parens < 0:
                parens += 1
                trim = true
            case "]" where brackets < 0:
                brackets += 1
                trim = true
            case "}" where braces < 0:
                braces += 1
                trim = true
            default:
                trim = false
            }
            if !trim { return end }
            end -= 1
        }
        return start
    }

    private static func balance(
        _ characters: ArraySlice<Character>,
        _ open: Character,
        _ close: Character
    ) -> Int {
        characters.reduce(0) { $0 + ($1 == open ? 1 : 0) - ($1 == close ? 1 : 0) }
    }
}
