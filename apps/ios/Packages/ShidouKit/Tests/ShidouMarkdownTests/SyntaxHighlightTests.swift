import XCTest

@testable import ShidouMarkdown

final class SyntaxHighlightTests: XCTestCase {
    private func spans(_ code: String, _ language: String?) -> [HighlightedSpan] {
        SyntaxHighlight.spans(of: code, language: language)
    }

    /// Lexing must be lossless. A highlighter that drops or reorders a
    /// character silently corrupts code the user is about to copy.
    private func assertLossless(_ code: String, _ language: String?, line: UInt = #line) {
        XCTAssertEqual(
            spans(code, language).map(\.text).joined(), code, "lexing lost content", line: line
        )
    }

    func testKnownLanguagesTokenizeKeywordsStringsAndComments() {
        let code = """
            // sets up the limiter
            let name = "shidou"
            let count = 42
            """
        let tokens = spans(code, "swift")
        XCTAssertTrue(tokens.contains { $0.token == .comment && $0.text.contains("limiter") })
        XCTAssertTrue(tokens.contains { $0.token == .keyword && $0.text == "let" })
        XCTAssertTrue(tokens.contains { $0.token == .string && $0.text == "\"shidou\"" })
        XCTAssertTrue(tokens.contains { $0.token == .number && $0.text == "42" })
        assertLossless(code, "swift")
    }

    func testAnUnknownLanguageStaysPlainRatherThanGuessing() {
        let tokens = spans("some brainfuck-ish ++[->+<]", "bf")
        XCTAssertEqual(tokens.map(\.token), [.plain])
    }

    func testNoLanguageStaysPlain() {
        XCTAssertEqual(spans("plain fence", nil).map(\.token), [.plain])
        XCTAssertTrue(spans("", nil).isEmpty)
    }

    /// An unterminated string is what a truncated paste looks like; it must not
    /// swallow the rest of the block.
    func testAnUnterminatedStringStopsAtTheLineEnd() {
        let code = "let a = \"open\nlet b = 1\n"
        let tokens = spans(code, "swift")
        XCTAssertTrue(tokens.contains { $0.token == .string && $0.text == "\"open" })
        XCTAssertTrue(tokens.contains { $0.token == .keyword && $0.text == "let" })
        assertLossless(code, "swift")
    }

    func testBlockCommentsCloseAndDoNotRunAway() {
        let code = "/* note */ let a = 1"
        let tokens = spans(code, "rust")
        XCTAssertEqual(tokens.first?.token, .comment)
        XCTAssertEqual(tokens.first?.text, "/* note */")
        assertLossless(code, "rust")
    }

    func testIdentifiersContainingDigitsAreNotSplitIntoNumbers() {
        let tokens = spans("let sha256 = 1", "swift")
        XCTAssertFalse(tokens.contains { $0.token == .number && $0.text == "256" })
        assertLossless("let sha256 = 1", "swift")
    }

    func testEveryGrammarIsLossless() {
        let code = """
            # a comment
            key = "value" -- trailing
            fn main() { return 0; } /* block */
            SELECT * FROM t WHERE a = 'x';
            """
        for language in [
            "swift", "rust", "ts", "js", "go", "python", "ruby", "bash", "json", "yaml", "sql",
            "java", "c",
        ] {
            assertLossless(code, language)
        }
    }

    func testTheHighlighterCachesAndDeclinesEnormousBlocks() async {
        let highlighter = SyntaxHighlighter(cacheLimit: 4)
        let first = await highlighter.spans(for: "let a = 1", language: "swift")
        let second = await highlighter.spans(for: "let a = 1", language: "swift")
        XCTAssertEqual(first, second)

        let huge = String(repeating: "let a = 1\n", count: 5_000)
        let plain = await highlighter.spans(for: huge, language: "swift")
        XCTAssertEqual(plain.map(\.token), [.plain])
    }
}

/// The file reader renders one row per line but the lexer has to see the whole
/// file, so the split happens after highlighting — including through a span
/// that itself crosses lines, which is the case a per-line lexer gets wrong.
final class SpansByLineTests: XCTestCase {
    func testSplitsSpansThatCrossLines() {
        let lines = SyntaxHighlight.spansByLine([
            HighlightedSpan(text: "let a = ", token: .plain),
            HighlightedSpan(text: "\"one\ntwo\"", token: .string),
            HighlightedSpan(text: "\n", token: .plain),
            HighlightedSpan(text: "end", token: .plain),
        ])
        XCTAssertEqual(lines.count, 3)
        XCTAssertEqual(lines[0].map(\.text), ["let a = ", "\"one"])
        XCTAssertEqual(lines[0].last?.token, .string)
        XCTAssertEqual(lines[1].map(\.text), ["two\""])
        XCTAssertEqual(lines[2].map(\.text), ["end"])
    }

    func testABlankLineIsALineOfItsOwn() {
        let lines = SyntaxHighlight.spansByLine([
            HighlightedSpan(text: "a\n\nb", token: .plain)
        ])
        XCTAssertEqual(lines.count, 3)
        XCTAssertTrue(lines[1].isEmpty)
    }

    func testTheWholeFileHighlightsLineByLine() {
        let lines = SyntaxHighlight.spansByLine(
            SyntaxHighlight.spans(of: "// note\nlet x = 1\n", language: "swift"))
        XCTAssertEqual(lines.count, 2, "a trailing newline ends the last line")
        XCTAssertEqual(lines[0].first?.token, .comment)
    }

    func testEmptyInputIsOneEmptyLine() {
        XCTAssertEqual(SyntaxHighlight.spansByLine([]).count, 1)
    }
}
