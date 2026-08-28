import Foundation

/// A unified `git` patch, parsed into files, hunks and lines.
///
/// The parity cut defers side-by-side diffs, so a phone renders one column:
/// each line carries the number it has on the side it belongs to, and a
/// context line carries both. That is the whole shape the Changes surface
/// needs, which is why this is a parser and not a diff engine — the daemon
/// already ran `git`, and re-deriving the diff on the phone would be work a
/// frame could reach.
public enum UnifiedDiff {
    public enum ChangeKind: Sendable, Hashable {
        case added, deleted, modified, renamed, binary
    }

    public enum LineKind: Sendable, Hashable {
        case context, addition, deletion
    }

    public struct Line: Sendable, Hashable, Identifiable {
        public var kind: LineKind
        public var content: String
        /// The line's number in the pre-image, for context and deletions.
        public var oldNumber: Int?
        /// The line's number in the post-image, for context and additions.
        public var newNumber: Int?
        /// Position within the file's line sequence, so `ForEach` has a stable
        /// identity even where two lines have the same text.
        public var index: Int

        public var id: Int { index }
    }

    public struct Hunk: Sendable, Hashable, Identifiable {
        public var header: String
        public var lines: [Line]
        public var index: Int

        public var id: Int { index }

        /// The part of the header after the second `@@` — `git` puts the
        /// enclosing function there, which is the only orientation a
        /// single-column diff can offer.
        public var context: String {
            guard let range = header.range(of: "@@", options: .backwards),
                range.upperBound < header.endIndex
            else { return "" }
            return String(header[range.upperBound...]).trimmingCharacters(in: .whitespaces)
        }
    }

    public struct File: Sendable, Hashable, Identifiable {
        public var path: String
        /// Set only for a rename, where the file list has two names to show.
        public var previousPath: String?
        public var change: ChangeKind
        public var hunks: [Hunk]
        public var additions: Int
        public var deletions: Int
        public var index: Int

        public var id: Int { index }

        public var name: String {
            path.split(separator: "/").last.map(String.init) ?? path
        }

        public var directory: String {
            let components = path.split(separator: "/").dropLast()
            return components.joined(separator: "/")
        }
    }

    public static func additions(_ files: [File]) -> Int {
        files.reduce(0) { $0 + $1.additions }
    }

    public static func deletions(_ files: [File]) -> Int {
        files.reduce(0) { $0 + $1.deletions }
    }

    /// Parse a whole multi-file patch. Anything unrecognised is skipped rather
    /// than thrown: a diff that renders most of itself beats an error screen
    /// over one header a future `git` learned to emit.
    public static func parse(_ patch: String) -> [File] {
        var lines = patch.components(separatedBy: "\n")
        // The final newline of a well-formed patch leaves one empty component
        // that is not a line of the diff.
        if lines.last == "" { lines.removeLast() }

        var files: [File] = []
        var current: Builder?
        for line in lines {
            if line.hasPrefix("diff --git ") {
                if let built = current?.build(index: files.count) { files.append(built) }
                current = Builder(gitHeader: line)
                continue
            }
            current?.take(line)
        }
        if let built = current?.build(index: files.count) { files.append(built) }
        return files
    }

    // MARK: - Building one file

    private struct Builder {
        private var path: String
        private var previousPath: String?
        private var renamedFrom: String?
        private var renamedTo: String?
        private var isNew = false
        private var isDeleted = false
        private var isBinary = false
        private var hunks: [Hunk] = []
        private var additions = 0
        private var deletions = 0
        private var lineIndex = 0
        private var oldNumber = 0
        private var newNumber = 0

        init(gitHeader: String) {
            let paths = Builder.headerPaths(gitHeader)
            path = paths.new ?? paths.old ?? ""
            previousPath = nil
        }

        mutating func take(_ line: String) {
            if line.hasPrefix("@@") {
                startHunk(line)
                return
            }
            if hunks.isEmpty || line.hasPrefix("diff --git ") {
                takeHeader(line)
                return
            }
            takeBody(line)
        }

        private mutating func takeHeader(_ line: String) {
            switch true {
            case line.hasPrefix("new file mode"):
                isNew = true
            case line.hasPrefix("deleted file mode"):
                isDeleted = true
            case line.hasPrefix("rename from "):
                renamedFrom = Builder.unquote(String(line.dropFirst("rename from ".count)))
            case line.hasPrefix("rename to "):
                renamedTo = Builder.unquote(String(line.dropFirst("rename to ".count)))
            case line.hasPrefix("Binary files "), line.hasPrefix("GIT binary patch"):
                isBinary = true
            case line.hasPrefix("--- "):
                let value = Builder.strip(prefix: String(line.dropFirst(4)))
                if let value { previousPath = value }
            case line.hasPrefix("+++ "):
                if let value = Builder.strip(prefix: String(line.dropFirst(4))) { path = value }
            default:
                break
            }
        }

        private mutating func startHunk(_ header: String) {
            let range = Builder.hunkRange(header)
            oldNumber = range.old
            newNumber = range.new
            hunks.append(Hunk(header: header, lines: [], index: hunks.count))
        }

        private mutating func takeBody(_ line: String) {
            // Metadata about the line above it, not a line of the file.
            guard !line.hasPrefix("\\") else { return }
            guard !hunks.isEmpty else { return }
            let marker = line.first
            let content = marker == nil ? "" : String(line.dropFirst())
            let entry: Line
            switch marker {
            case "+":
                additions += 1
                entry = Line(
                    kind: .addition, content: content, oldNumber: nil, newNumber: newNumber,
                    index: lineIndex
                )
                newNumber += 1
            case "-":
                deletions += 1
                entry = Line(
                    kind: .deletion, content: content, oldNumber: oldNumber, newNumber: nil,
                    index: lineIndex
                )
                oldNumber += 1
            case " ", nil:
                // A context line, including the bare empty line a transport
                // that trims trailing whitespace leaves behind. Dropping it
                // would shift every number below it.
                entry = Line(
                    kind: .context, content: content, oldNumber: oldNumber, newNumber: newNumber,
                    index: lineIndex
                )
                oldNumber += 1
                newNumber += 1
            default:
                // Anything else between hunks (a stray `index` line, say) is
                // not part of the file's content.
                return
            }
            lineIndex += 1
            hunks[hunks.count - 1].lines.append(entry)
        }

        func build(index: Int) -> File? {
            guard !path.isEmpty else { return nil }
            let change: ChangeKind
            if isBinary {
                change = .binary
            } else if renamedTo != nil || renamedFrom != nil {
                change = .renamed
            } else if isNew {
                change = .added
            } else if isDeleted {
                change = .deleted
            } else {
                change = .modified
            }
            return File(
                path: renamedTo ?? path,
                previousPath: change == .renamed ? (renamedFrom ?? previousPath) : nil,
                change: change,
                hunks: hunks,
                additions: additions,
                deletions: deletions,
                index: index
            )
        }

        // MARK: Header parsing

        /// `--- a/x` / `+++ b/x`, with `/dev/null` for a side that has no file
        /// and an optional `a/`/`b/` prefix `git` adds by default.
        static func strip(prefix value: String) -> String? {
            let unquoted = unquote(value.trimmingCharacters(in: .whitespaces))
            guard unquoted != "/dev/null" else { return nil }
            if unquoted.hasPrefix("a/") || unquoted.hasPrefix("b/") {
                return String(unquoted.dropFirst(2))
            }
            return unquoted
        }

        /// `diff --git a/old b/new`, where either name may be quoted and may
        /// itself contain spaces. Quoted names are unambiguous; unquoted ones
        /// are split on the ` b/` that separates the two halves.
        static func headerPaths(_ header: String) -> (old: String?, new: String?) {
            let rest = String(header.dropFirst("diff --git ".count))
            if rest.hasPrefix("\"") {
                let parts = quotedPair(rest)
                return (strip(prefix: parts.0 ?? ""), strip(prefix: parts.1 ?? ""))
            }
            guard let separator = rest.range(of: " b/") else {
                return (nil, strip(prefix: rest))
            }
            return (
                strip(prefix: String(rest[rest.startIndex..<separator.lowerBound])),
                strip(prefix: String(rest[rest.index(after: separator.lowerBound)...]))
            )
        }

        private static func quotedPair(_ value: String) -> (String?, String?) {
            var quoted: [String] = []
            var buffer = ""
            var inside = false
            var escaped = false
            for character in value {
                if escaped {
                    buffer.append(character)
                    escaped = false
                    continue
                }
                if character == "\\" && inside {
                    escaped = true
                    continue
                }
                if character == "\"" {
                    if inside { quoted.append(buffer) }
                    buffer = ""
                    inside.toggle()
                    continue
                }
                if inside { buffer.append(character) }
            }
            return (quoted.first, quoted.count > 1 ? quoted[1] : nil)
        }

        static func unquote(_ value: String) -> String {
            guard value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 else {
                return value
            }
            return String(value.dropFirst().dropLast()).replacingOccurrences(of: "\\\"", with: "\"")
        }

        /// `@@ -old[,count] +new[,count] @@ context`. A missing count means one
        /// line, which is what `git` emits for a single-line hunk.
        static func hunkRange(_ header: String) -> (old: Int, new: Int) {
            var old = 1
            var new = 1
            for field in header.split(separator: " ") {
                guard let first = field.first, first == "-" || first == "+" else { continue }
                let number = Int(field.dropFirst().prefix { $0.isNumber }) ?? 1
                if first == "-" { old = number } else { new = number }
            }
            return (old, new)
        }
    }
}
