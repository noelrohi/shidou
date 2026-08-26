// PROTOTYPE — streaming transcript spike (wayfinder #9). Throwaway.
//
// Swift port of `src/md/mend.rs`: closes hanging inline markers in a
// streaming markdown tail so styling stays stable while the closer is still
// in flight. Only the display parse sees mended text; the canonical source
// is untouched.

import Foundation

enum SpikeMend {
    /// Destination for a link whose URL is still streaming.
    static let pendingLinkURL = "shidou:pending-link"
    private static let zeroWidthSpace: Character = "\u{200B}"

    private struct OpenDelimiter {
        var marker: Character
        var owed: Int
        var openedAt: Int
    }

    /// Repair hanging inline markers. Returns `nil` when nothing needs repair.
    static func closeHanging(_ text: String) -> String? {
        let chars = Array(text)
        func at(_ index: Int) -> Character? {
            index >= 0 && index < chars.count ? chars[index] : nil
        }

        var delimiters: [OpenDelimiter] = []
        var brackets: [Int] = []
        // Open inline code span: (backtick run length, char index of content).
        var code: (run: Int, contentAt: Int)?
        var lastContent: Int?
        // Char index of the `]` whose `](…` URL runs off the end of the tail.
        var pendingURL: Int?

        var index = 0
        scan: while index < chars.count {
            let ch = chars[index]

            if code == nil && ch == "\\" {
                if index + 1 < chars.count { lastContent = index + 1 }
                index += 2
                continue
            }

            if ch == "`" {
                let run = runLength(chars, index)
                if let open = code {
                    if run == open.run {
                        code = nil
                    }
                    lastContent = index + run - 1
                } else {
                    code = (run, index + run)
                }
                index += run
                continue
            }

            if code != nil {
                lastContent = index
                index += 1
                continue
            }

            switch ch {
            case "*", "_", "~":
                let run = runLength(chars, index)
                scanDelimiter(
                    &delimiters, marker: ch, run: run, index: index,
                    lastContent: &lastContent, at: at
                )
                index += run
            case "[":
                brackets.append(index)
                index += 1
            case "]":
                if let open = brackets.popLast() {
                    // Emphasis opened inside a completed `[…]` and never
                    // closed there stays literal.
                    delimiters.removeAll { $0.openedAt >= open }
                    if at(index + 1) == "(" {
                        // Consume the URL through its balanced `)`.
                        var scanAt = index + 2
                        var depth = 0
                        url: while true {
                            switch at(scanAt) {
                            case "(": depth += 1
                            case ")" where depth == 0: break url
                            case ")": depth -= 1
                            case .some: break
                            case nil:
                                pendingURL = index
                                break url
                            }
                            scanAt += 1
                        }
                        if pendingURL != nil { break scan }
                        lastContent = scanAt
                        index = scanAt + 1
                        continue
                    }
                }
                lastContent = index
                index += 1
            case let ch where ch.isWhitespace:
                index += 1
            default:
                lastContent = index
                index += 1
            }
        }

        // Closers must sit immediately after the last content character.
        let contentEnd = lastContent.map { $0 + 1 } ?? chars.count

        if let bracket = pendingURL {
            let cut = bracket
            var closers = ""
            appendClosers(&closers, delimiters, lastContent, limit: bracket)
            var mended = String(chars[..<min(contentEnd, cut)])
            mended += closers
            mended += String(chars[min(contentEnd, cut)..<cut])
            mended += "](\(pendingLinkURL))"
            return mended
        }

        var closers = ""
        if let (run, contentAt) = code, let content = lastContent, content >= contentAt {
            closers += String(repeating: "`", count: run)
        }
        appendClosers(&closers, delimiters, lastContent, limit: chars.count)
        if let bracket = brackets.last, let content = lastContent, content > bracket {
            closers += "](\(pendingLinkURL))"
        }

        let setextGuard = needsSetextGuard(text)
        if closers.isEmpty && !setextGuard { return nil }

        var mended = String(chars[..<contentEnd]) + closers + String(chars[contentEnd...])
        if setextGuard { mended.append(zeroWidthSpace) }
        return mended
    }

    private static func appendClosers(
        _ out: inout String,
        _ delimiters: [OpenDelimiter],
        _ lastContent: Int?,
        limit: Int
    ) {
        for delimiter in delimiters.reversed() {
            if delimiter.openedAt >= limit { continue }
            guard let content = lastContent, content >= delimiter.openedAt else { continue }
            out += String(repeating: delimiter.marker, count: delimiter.owed)
        }
    }

    private static func runLength(_ chars: [Character], _ start: Int) -> Int {
        let marker = chars[start]
        var end = start
        while end < chars.count && chars[end] == marker { end += 1 }
        return end - start
    }

    private static func scanDelimiter(
        _ delimiters: inout [OpenDelimiter],
        marker: Character,
        run: Int,
        index: Int,
        lastContent: inout Int?,
        at: (Int) -> Character?
    ) {
        // A lone `~` is literal in GFM.
        if marker == "~" && run < 2 {
            lastContent = index + run - 1
            return
        }

        let before = at(index - 1)
        let after = at(index + run)
        let canClose = before.map { !$0.isWhitespace } ?? false
        let canOpen = after.map { !$0.isWhitespace } ?? false

        if canClose,
            let position = delimiters.lastIndex(where: { $0.marker == marker }),
            let content = lastContent, content >= delimiters[position].openedAt
        {
            let owed = delimiters[position].owed
            if run >= owed {
                delimiters.removeSubrange(position...)
            } else {
                delimiters[position].owed = owed - run
                delimiters.removeSubrange((position + 1)...)
            }
            lastContent = index + run - 1
            return
        }

        // `_` does not open inside a word.
        if marker == "_", let before, before.isLetter || before.isNumber {
            lastContent = index + run - 1
            return
        }

        if canOpen {
            delimiters.append(OpenDelimiter(marker: marker, owed: run, openedAt: index + run))
        } else {
            lastContent = index + run - 1
        }
    }

    /// A final line of only `-` or `=` directly under a text line would flash
    /// the paragraph as a setext heading for one chunk.
    private static func needsSetextGuard(_ text: String) -> Bool {
        if text.hasSuffix("\n") { return false }
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        guard let last = lines.popLast() else { return false }
        let trimmed = String(last).trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty,
            trimmed.allSatisfy({ $0 == "-" }) || trimmed.allSatisfy({ $0 == "=" })
        else { return false }
        guard let previous = lines.last else { return false }
        let head = String(previous).trimmingCharacters(in: .whitespaces)
        guard !head.isEmpty else { return false }
        return !["-", "=", "#", ">", "`"].contains(String(head.prefix(1)))
    }
}
