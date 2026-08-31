import Foundation
import ShidouProtocol

// Port of `apps/web/src/lib/composer-autocomplete.ts` and the `fuzzyScore`
// half of `palette-search.ts`. The suggestion list is deliberately the simple
// server-backed one the parity cut asked for: the daemon answers with the
// project's files and slash commands, and everything after that — detection,
// ranking, replacement, template expansion — happens here.
//
// Offsets are grapheme-cluster offsets into the composer's text. The UIKit
// wrapper converts its UTF-16 selection offsets at the boundary, so this file
// can index an `Array<Character>` consistently.

/// Converts between the grapheme-cluster offsets the composer model uses and
/// the UTF-16 offsets UIKit's text system reports. They differ as soon as a
/// prompt contains emoji or a composed character.
public enum ComposerTextOffset {
    public static func characterOffset(in text: String, utf16Offset: Int) -> Int {
        let target = max(0, utf16Offset)
        var consumed = 0
        var characters = 0
        for character in text {
            let length = String(character).utf16.count
            guard consumed + length <= target else { break }
            consumed += length
            characters += 1
        }
        return characters
    }

    public static func utf16Offset(in text: String, characterOffset: Int) -> Int {
        let target = max(0, characterOffset)
        var offset = 0
        for (index, character) in text.enumerated() {
            guard index < target else { break }
            offset += String(character).utf16.count
        }
        return offset
    }
}

public enum ComposerTriggerKind: Sendable {
    case command
    case file
}

public struct ComposerTrigger: Hashable, Sendable {
    public var kind: ComposerTriggerKind
    public var query: String
    public var start: Int
    public var end: Int

    public init(kind: ComposerTriggerKind, query: String, start: Int, end: Int) {
        self.kind = kind
        self.query = query
        self.start = start
        self.end = end
    }
}

extension ComposerTriggerKind: Hashable {}

public enum ComposerAutocompleteRow: Identifiable, Hashable, Sendable {
    case command(SlashCommand)
    case file(FileEntry)

    public var id: String {
        switch self {
        case .command(let command): return "command:\(command.scope.rawValue):\(command.name)"
        case .file(let file): return "file:\(file.path)"
        }
    }
}

public enum ComposerAutocomplete {
    public static let cap = 64

    /// The token the caret is sitting in, if it is one the composer completes.
    /// A slash command only counts at the start of its own line; a file
    /// mention is the current whitespace-delimited token.
    public static func trigger(in text: String, cursor: Int) -> ComposerTrigger? {
        let characters = Array(text)
        let end = max(0, min(cursor, characters.count))
        var lineStart = 0
        if end > 0 {
            for index in stride(from: end - 1, through: 0, by: -1) where characters[index] == "\n" {
                lineStart = index + 1
                break
            }
        }
        let linePrefix = String(characters[lineStart..<end])
        if linePrefix.hasPrefix("/") {
            let query = String(linePrefix.dropFirst())
            if query.contains(where: \.isWhitespace) { return nil }
            return ComposerTrigger(kind: .command, query: query, start: lineStart, end: end)
        }

        var tokenStart = end
        while tokenStart > 0, !characters[tokenStart - 1].isWhitespace { tokenStart -= 1 }
        let token = String(characters[tokenStart..<end])
        guard token.hasPrefix("@") else { return nil }
        return ComposerTrigger(
            kind: .file, query: String(token.dropFirst()), start: tokenStart, end: end)
    }

    /// Folds the provider's live command list into the daemon's discovered one.
    /// A discovered command keeps its template; a reported one the daemon never
    /// found on disk joins as a builtin.
    public static func mergeCommands(
        discovered: [SlashCommand],
        reported: [ReportedCommand]
    ) -> [SlashCommand] {
        var merged = discovered
        for report in reported {
            if let index = merged.firstIndex(where: { $0.name == report.name }) {
                if merged[index].description.isEmpty {
                    merged[index].description = report.description
                }
                continue
            }
            merged.append(SlashCommand(
                name: report.name, description: report.description, scope: .builtin))
        }
        return merged.sorted {
            $0.scope.displayRank == $1.scope.displayRank
                ? $0.name < $1.name
                : $0.scope.displayRank < $1.scope.displayRank
        }
    }

    public static func rows(
        for trigger: ComposerTrigger,
        commands: [SlashCommand],
        files: [FileEntry],
        cap: Int = ComposerAutocomplete.cap
    ) -> [ComposerAutocompleteRow] {
        let source: [(row: ComposerAutocompleteRow, candidate: String)]
        switch trigger.kind {
        case .command:
            source = commands.map { (.command($0), $0.name) }
        case .file:
            source = files.map { (.file($0), $0.path) }
        }
        if trigger.query.trimmingCharacters(in: .whitespaces).isEmpty {
            return source.prefix(cap).map(\.row)
        }
        return source.enumerated()
            .compactMap { index, item -> (ComposerAutocompleteRow, Int, Int)? in
                guard let score = fuzzyScore(query: trigger.query, candidate: item.candidate)
                else { return nil }
                return (item.row, index, score)
            }
            .sorted { $0.2 == $1.2 ? $0.1 < $1.1 : $0.2 > $1.2 }
            .prefix(cap)
            .map(\.0)
    }

    /// Swaps the trigger for the chosen row and returns where the caret goes.
    /// The trailing space is part of the insertion: it closes the token, so
    /// the suggestion list does not immediately reopen on what was accepted.
    public static func replacing(
        _ text: String,
        trigger: ComposerTrigger,
        with row: ComposerAutocompleteRow
    ) -> (text: String, cursor: Int) {
        let insert: String
        switch row {
        case .command(let command): insert = "/\(command.name) "
        case .file(let file): insert = "@\(file.path) "
        }
        let characters = Array(text)
        let prefix = String(characters[0..<min(trigger.start, characters.count)])
        let suffix = String(characters[min(trigger.end, characters.count)...])
        return (prefix + insert + suffix, trigger.start + insert.count)
    }

    // MARK: - Slash-command submission

    /// Port of `expandCommandTemplate`: `$ARGUMENTS`, `$@`, and `$1`–`$9`.
    /// A template with no placeholder gets the arguments appended instead, so
    /// nothing the user typed is silently dropped.
    public static func expandTemplate(_ template: String, arguments: String) -> String {
        let positional = arguments.split(whereSeparator: \.isWhitespace).map(String.init)
        var expanded = ""
        var consumedArguments = false
        var rest = Substring(template)
        while let index = rest.firstIndex(of: "$") {
            expanded += rest[rest.startIndex..<index]
            let after = rest[rest.index(after: index)...]
            if after.hasPrefix("ARGUMENTS") {
                expanded += arguments
                consumedArguments = true
                rest = after.dropFirst("ARGUMENTS".count)
            } else if after.hasPrefix("@") {
                expanded += arguments
                consumedArguments = true
                rest = after.dropFirst()
            } else if let first = after.first, let slot = first.wholeNumberValue, slot >= 1 {
                expanded += positional.count >= slot ? positional[slot - 1] : ""
                consumedArguments = true
                rest = after.dropFirst()
            } else {
                expanded += "$"
                rest = after
            }
        }
        expanded += rest
        if !consumedArguments && !arguments.isEmpty { expanded += "\n\n\(arguments)" }
        return expanded
    }

    /// What a `/command` submission should actually send the provider, or
    /// `nil` when the text goes through untouched.
    public static func expandedSubmission(
        provider: ProviderKind,
        prompt: String,
        commands: [SlashCommand]
    ) -> String? {
        guard prompt.hasPrefix("/") else { return nil }
        let invocation = String(prompt.dropFirst())
        let whitespace = invocation.firstIndex(where: \.isWhitespace)
        let name = whitespace.map { String(invocation[..<$0]) } ?? invocation
        let arguments = whitespace
            .map { String(invocation[$0...]).trimmingCharacters(in: .whitespacesAndNewlines) } ?? ""
        if commands.contains(where: { $0.name == name && $0.scope == .skill }) {
            switch provider {
            case .codex, .fx: return "$\(invocation)"
            case .pi, .ohMyPi: return "/skill:\(invocation)"
            default: break
            }
        }
        guard let template = commands.first(where: { $0.name == name && $0.template != nil })?
            .template
        else { return nil }
        return expandTemplate(template, arguments: arguments)
    }

    /// Codex's `/fast` is a local toggle, not a prompt: the composer flips the
    /// service tier rather than sending anything. Only the builtin the daemon
    /// resolved counts — a project command of the same name is a real prompt.
    public static func isFastModeToggle(
        provider: ProviderKind,
        prompt: String,
        commands: [SlashCommand]
    ) -> Bool {
        provider == .codex
            && prompt.trimmingCharacters(in: .whitespacesAndNewlines) == "/fast"
            && commands.contains {
                $0.name == "fast" && $0.scope == .builtin && $0.template == nil
            }
    }

    public static func toggledFastServiceTier(
        current: String?,
        serviceTiers: [ProviderModelOption]
    ) -> String? {
        guard let fast = serviceTiers.first(where: {
            ["fast", "priority"].contains($0.id) || $0.label.lowercased() == "fast"
        }) else { return nil }
        return current == fast.id ? "default" : fast.id
    }

    // MARK: - Ranking

    /// Port of `fuzzyScore`. Contiguous matches dominate subsequences; earlier
    /// and tighter matches win.
    public static func fuzzyScore(query: String, candidate: String) -> Int? {
        let needle = Array(query.trimmingCharacters(in: .whitespaces).lowercased())
        let haystack = Array(candidate.lowercased())
        if needle.isEmpty { return 0 }

        if let contiguous = indexOf(needle, in: haystack) {
            return 100_000 + needle.count * 1_000 - contiguous
        }

        var score = 0
        var nextNeedle = 0
        var previousMatch = -2
        var index = 0
        while index < haystack.count && nextNeedle < needle.count {
            defer { index += 1 }
            guard haystack[index] == needle[nextNeedle] else { continue }
            score += index == previousMatch + 1 ? 200 : 40
            if index == 0 || isBoundary(haystack[index - 1]) { score += 100 }
            score += max(0, 50 - index)
            previousMatch = index
            nextNeedle += 1
        }
        return nextNeedle == needle.count ? score : nil
    }

    private static func isBoundary(_ character: Character) -> Bool {
        character.isWhitespace || "/_.#-".contains(character)
    }

    private static func indexOf(_ needle: [Character], in haystack: [Character]) -> Int? {
        guard needle.count <= haystack.count else { return nil }
        for start in 0...(haystack.count - needle.count)
        where Array(haystack[start..<start + needle.count]) == needle {
            return start
        }
        return nil
    }
}
