import Foundation

/// What a highlighted span means, so the view picks the colour and this file
/// stays free of one.
public enum SyntaxToken: Sendable, Hashable {
    case plain
    case keyword
    case string
    case number
    case comment
    case type
    case punctuation
}

public struct HighlightedSpan: Sendable, Hashable {
    public var text: String
    public var token: SyntaxToken

    public init(text: String, token: SyntaxToken) {
        self.text = text
        self.token = token
    }
}

/// A small, allocation-light lexer for fenced code blocks.
///
/// Highlighting a streaming fence is wasted work and worse: the tail of an
/// unterminated string or comment lexes differently on every chunk, so the
/// colours flicker. The transcript therefore highlights only once the fence
/// closes (`MarkdownBlock.codeBlock(fenceClosed:)`), and does it off the main
/// thread through `SyntaxHighlighter`.
///
/// Deliberately not a full grammar: it recognizes comments, strings, numbers,
/// keywords and capitalized identifiers, which is what makes a code block
/// readable at a glance on a phone. Anything it does not know lexes as plain
/// text, which is exactly the unhighlighted rendering.
public enum SyntaxHighlight {
    public static func spans(of code: String, language: String?) -> [HighlightedSpan] {
        guard let grammar = Grammar.named(language) else {
            return code.isEmpty ? [] : [HighlightedSpan(text: code, token: .plain)]
        }
        var spans: [HighlightedSpan] = []
        var plain = ""
        let characters = Array(code)
        var index = 0

        func flushPlain() {
            guard !plain.isEmpty else { return }
            spans.append(HighlightedSpan(text: plain, token: .plain))
            plain = ""
        }

        func emit(_ text: String, _ token: SyntaxToken) {
            flushPlain()
            spans.append(HighlightedSpan(text: text, token: token))
        }

        while index < characters.count {
            let character = characters[index]

            if let end = grammar.lineCommentEnd(characters, index) {
                emit(String(characters[index..<end]), .comment)
                index = end
                continue
            }
            if let end = grammar.blockCommentEnd(characters, index) {
                emit(String(characters[index..<end]), .comment)
                index = end
                continue
            }
            if grammar.stringDelimiters.contains(character) {
                let end = stringEnd(characters, from: index, escapes: grammar.escapesInStrings)
                emit(String(characters[index..<end]), .string)
                index = end
                continue
            }
            if character.isNumber, !isIdentifierContinuation(characters, before: index) {
                var end = index
                while end < characters.count,
                    characters[end].isHexDigit || "._xXeEbBoO".contains(characters[end])
                {
                    end += 1
                }
                emit(String(characters[index..<end]), .number)
                index = end
                continue
            }
            if isIdentifierStart(character) {
                var end = index
                while end < characters.count, isIdentifierContinuation(characters[end]) { end += 1 }
                let word = String(characters[index..<end])
                if grammar.keywords.contains(word) {
                    emit(word, .keyword)
                } else if let first = word.first, first.isUppercase {
                    emit(word, .type)
                } else {
                    plain += word
                }
                index = end
                continue
            }
            plain.append(character)
            index += 1
        }
        flushPlain()
        return spans
    }

    private static func stringEnd(_ characters: [Character], from start: Int, escapes: Bool) -> Int {
        let quote = characters[start]
        var index = start + 1
        while index < characters.count {
            if escapes, characters[index] == "\\" {
                index += 2
                continue
            }
            if characters[index] == quote { return index + 1 }
            // An unterminated string stops at the line end rather than
            // swallowing the rest of the block.
            if characters[index] == "\n" { return index }
            index += 1
        }
        return characters.count
    }

    private static func isIdentifierStart(_ character: Character) -> Bool {
        character.isLetter || character == "_" || character == "$" || character == "#"
            || character == "@"
    }

    private static func isIdentifierContinuation(_ character: Character) -> Bool {
        isIdentifierStart(character) || character.isNumber
    }

    private static func isIdentifierContinuation(_ characters: [Character], before index: Int) -> Bool {
        index > 0 && isIdentifierContinuation(characters[index - 1])
    }
}

// MARK: - Grammars

extension SyntaxHighlight {
    struct Grammar {
        var keywords: Set<String>
        var lineComment: [String]
        var blockComment: (open: String, close: String)?
        var stringDelimiters: Set<Character>
        var escapesInStrings = true

        func lineCommentEnd(_ characters: [Character], _ index: Int) -> Int? {
            for marker in lineComment where matches(characters, index, marker) {
                var end = index
                while end < characters.count, characters[end] != "\n" { end += 1 }
                return end
            }
            return nil
        }

        func blockCommentEnd(_ characters: [Character], _ index: Int) -> Int? {
            guard let blockComment, matches(characters, index, blockComment.open) else { return nil }
            var end = index + blockComment.open.count
            while end < characters.count, !matches(characters, end, blockComment.close) { end += 1 }
            return min(characters.count, end + blockComment.close.count)
        }

        private func matches(_ characters: [Character], _ index: Int, _ marker: String) -> Bool {
            let marker = Array(marker)
            guard index + marker.count <= characters.count else { return false }
            for offset in marker.indices where characters[index + offset] != marker[offset] {
                return false
            }
            return true
        }

        /// Aliases follow the fence infos a provider actually emits.
        static func named(_ language: String?) -> Grammar? {
            guard let language = language?.lowercased(), !language.isEmpty else { return nil }
            switch language {
            case "swift":
                return curly(keywords: swiftKeywords)
            case "rust", "rs":
                return curly(keywords: rustKeywords)
            case "ts", "typescript", "tsx", "js", "javascript", "jsx", "mjs":
                return curly(keywords: javascriptKeywords, stringDelimiters: ["\"", "'", "`"])
            case "go":
                return curly(keywords: goKeywords, stringDelimiters: ["\"", "`"])
            case "java", "kotlin", "kt", "c", "cpp", "c++", "objc", "cs", "csharp":
                return curly(keywords: cFamilyKeywords)
            case "python", "py":
                return Grammar(
                    keywords: pythonKeywords,
                    lineComment: ["#"],
                    blockComment: nil,
                    stringDelimiters: ["\"", "'"]
                )
            case "ruby", "rb":
                return Grammar(
                    keywords: rubyKeywords,
                    lineComment: ["#"],
                    blockComment: nil,
                    stringDelimiters: ["\"", "'"]
                )
            case "sh", "bash", "zsh", "shell", "console", "fish":
                return Grammar(
                    keywords: shellKeywords,
                    lineComment: ["#"],
                    blockComment: nil,
                    stringDelimiters: ["\"", "'"]
                )
            case "json":
                return Grammar(
                    keywords: ["true", "false", "null"],
                    lineComment: [],
                    blockComment: nil,
                    stringDelimiters: ["\""]
                )
            case "yaml", "yml", "toml", "ini":
                return Grammar(
                    keywords: ["true", "false", "null", "yes", "no"],
                    lineComment: ["#"],
                    blockComment: nil,
                    stringDelimiters: ["\"", "'"]
                )
            case "sql":
                return Grammar(
                    keywords: sqlKeywords,
                    lineComment: ["--"],
                    blockComment: ("/*", "*/"),
                    stringDelimiters: ["'", "\""]
                )
            default:
                return nil
            }
        }

        private static func curly(
            keywords: Set<String>,
            stringDelimiters: Set<Character> = ["\"", "'"]
        ) -> Grammar {
            Grammar(
                keywords: keywords,
                lineComment: ["//"],
                blockComment: ("/*", "*/"),
                stringDelimiters: stringDelimiters
            )
        }
    }
}

extension SyntaxHighlight.Grammar {
    static let swiftKeywords: Set<String> = [
        "actor", "any", "as", "associatedtype", "async", "await", "break", "case", "catch",
        "class", "continue", "default", "defer", "deinit", "do", "else", "enum", "extension",
        "fallthrough", "false", "fileprivate", "final", "for", "func", "guard", "if", "import",
        "in", "indirect", "init", "inout", "internal", "is", "lazy", "let", "mutating", "nil",
        "nonisolated", "open", "operator", "private", "protocol", "public", "repeat", "rethrows",
        "return", "self", "Self", "some", "static", "struct", "subscript", "super", "switch",
        "throw", "throws", "true", "try", "typealias", "var", "where", "while",
    ]

    static let rustKeywords: Set<String> = [
        "as", "async", "await", "break", "const", "continue", "crate", "dyn", "else", "enum",
        "extern", "false", "fn", "for", "if", "impl", "in", "let", "loop", "match", "mod", "move",
        "mut", "pub", "ref", "return", "self", "Self", "static", "struct", "super", "trait",
        "true", "type", "union", "unsafe", "use", "where", "while",
    ]

    static let javascriptKeywords: Set<String> = [
        "as", "async", "await", "break", "case", "catch", "class", "const", "continue", "debugger",
        "default", "delete", "do", "else", "export", "extends", "false", "finally", "for",
        "from", "function", "if", "implements", "import", "in", "instanceof", "interface", "let",
        "new", "null", "of", "return", "satisfies", "super", "switch", "this", "throw", "true",
        "try", "type", "typeof", "undefined", "var", "void", "while", "yield",
    ]

    static let goKeywords: Set<String> = [
        "break", "case", "chan", "const", "continue", "default", "defer", "else", "fallthrough",
        "for", "func", "go", "goto", "if", "import", "interface", "map", "package", "range",
        "return", "select", "struct", "switch", "type", "var", "nil", "true", "false",
    ]

    static let cFamilyKeywords: Set<String> = [
        "abstract", "auto", "bool", "break", "case", "catch", "char", "class", "const",
        "constexpr", "continue", "default", "delete", "do", "double", "else", "enum", "extends",
        "extern", "false", "final", "finally", "float", "for", "goto", "if", "implements",
        "import", "inline", "instanceof", "int", "interface", "long", "namespace", "new", "null",
        "override", "package", "private", "protected", "public", "return", "short", "sizeof",
        "static", "struct", "switch", "template", "this", "throw", "true", "try", "typedef",
        "typename", "union", "unsigned", "using", "virtual", "void", "volatile", "while",
    ]

    static let pythonKeywords: Set<String> = [
        "and", "as", "assert", "async", "await", "break", "class", "continue", "def", "del",
        "elif", "else", "except", "False", "finally", "for", "from", "global", "if", "import",
        "in", "is", "lambda", "None", "nonlocal", "not", "or", "pass", "raise", "return", "True",
        "try", "while", "with", "yield",
    ]

    static let rubyKeywords: Set<String> = [
        "alias", "and", "begin", "break", "case", "class", "def", "defined?", "do", "else",
        "elsif", "end", "ensure", "false", "for", "if", "in", "module", "next", "nil", "not",
        "or", "redo", "rescue", "retry", "return", "self", "super", "then", "true", "unless",
        "until", "when", "while", "yield",
    ]

    static let shellKeywords: Set<String> = [
        "case", "do", "done", "elif", "else", "esac", "export", "fi", "for", "function", "if",
        "in", "local", "return", "set", "then", "until", "while",
    ]

    static let sqlKeywords: Set<String> = [
        "and", "as", "asc", "by", "create", "delete", "desc", "distinct", "drop", "exists",
        "from", "group", "having", "index", "inner", "insert", "into", "join", "left", "limit",
        "not", "null", "on", "or", "order", "outer", "select", "set", "table", "union", "update",
        "values", "where", "with",
    ]
}

// MARK: - Off-main cache

/// Highlights fenced code away from the main thread and caches the result.
///
/// Row builders run for every visible block on every frame, so the transcript
/// asks this store for an answer it already has and gets `nil` — plain text —
/// on a miss. The work lands later and the view updates then, which is the
/// same discipline the desktop applies to anything a frame can reach.
public actor SyntaxHighlighter {
    private struct Key: Hashable {
        let code: String
        let language: String?
    }

    private var cache: [Key: [HighlightedSpan]] = [:]
    private let limit: Int
    private var order: [Key] = []

    /// Code blocks past this many characters are left plain: a phone showing a
    /// 5,000-line file has already lost, and lexing it would cost more than
    /// the readability it buys.
    public static let maximumHighlightedCharacters = 20_000

    public init(cacheLimit: Int = 256) {
        self.limit = cacheLimit
    }

    public func spans(for code: String, language: String?) -> [HighlightedSpan] {
        let key = Key(code: code, language: language)
        if let cached = cache[key] { return cached }
        guard code.count <= Self.maximumHighlightedCharacters else {
            return [HighlightedSpan(text: code, token: .plain)]
        }
        let spans = SyntaxHighlight.spans(of: code, language: language)
        cache[key] = spans
        order.append(key)
        if order.count > limit {
            cache.removeValue(forKey: order.removeFirst())
        }
        return spans
    }
}
