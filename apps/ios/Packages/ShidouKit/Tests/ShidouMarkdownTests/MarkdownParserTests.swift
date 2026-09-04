import XCTest

@testable import ShidouMarkdown

/// Mirrors the desktop's `src/md/parser.rs` tests. The two clients render the
/// same provider output, so a divergence here is a divergence a user can see
/// by opening the same task on both.
final class MarkdownParserTests: XCTestCase {
    private func text(_ block: MarkdownBlock) -> String {
        switch block {
        case .paragraph(let runs), .heading(_, let runs):
            return runs.map(\.text).joined()
        default:
            XCTFail("expected a text block, got \(block)")
            return ""
        }
    }

    func testParsesTopLevelBlocksWithSourceRanges() {
        let source = "# Title\n\nBody text.\n\n```rust\nfn main() {}\n```\n"
        let blocks = MarkdownParser.parse(source)

        XCTAssertEqual(blocks.count, 3)
        guard case .heading(let level, let runs) = blocks[0].block else {
            return XCTFail("expected a heading")
        }
        XCTAssertEqual(level, 1)
        XCTAssertEqual(runs.map(\.text).joined(), "Title")
        XCTAssertEqual(text(blocks[1].block), "Body text.")
        guard case .codeBlock(let language, let code, let closed) = blocks[2].block else {
            return XCTFail("expected a code block")
        }
        XCTAssertEqual(language, "rust")
        XCTAssertEqual(code, "fn main() {}")
        XCTAssertTrue(closed)

        // Ranges have to line up with the source or incremental appends slice
        // the document in the wrong place.
        let bytes = Array(source.utf8)
        let heading = String(bytes: bytes[blocks[0].range], encoding: .utf8)
        XCTAssertEqual(heading?.trimmingCharacters(in: .whitespacesAndNewlines), "# Title")
    }

    func testInlineStylesNestAndMerge() {
        let blocks = MarkdownParser.parse("A **bold *both* more** tail and `code`.")
        guard case .paragraph(let runs) = blocks[0].block else {
            return XCTFail("expected a paragraph")
        }
        XCTAssertEqual(runs.map(\.text).joined(), "A bold both more tail and code.")
        XCTAssertTrue(runs.contains { $0.text == "both" && $0.style.bold && $0.style.italic })
        XCTAssertTrue(runs.contains { $0.text == "code" && $0.style.code })
    }

    func testBareWebURLsBecomeLinksWithoutSwallowingProsePunctuation() {
        let source = "See https://example.com/docs?q=one, then "
            + "(https://en.wikipedia.org/wiki/Rust_(programming_language))."
        let blocks = MarkdownParser.parse(source)
        guard case .paragraph(let runs) = blocks[0].block else {
            return XCTFail("expected a paragraph")
        }
        let links = runs.compactMap { run in run.style.link.map { (run.text, $0) } }

        XCTAssertEqual(links.count, 2)
        XCTAssertEqual(links.first?.0, "https://example.com/docs?q=one")
        XCTAssertEqual(links.first?.1, "https://example.com/docs?q=one")
        XCTAssertEqual(links.last?.0, "https://en.wikipedia.org/wiki/Rust_(programming_language)")
        // Linkification must be lossless: the visible paragraph is unchanged.
        XCTAssertEqual(runs.map(\.text).joined(), source)
    }

    func testExplicitLinksAndInlineCodeAreNotRelinkified() {
        let blocks = MarkdownParser.parse(
            "[docs at https://example.com](https://shidou.gg) and `https://example.com/code`"
        )
        guard case .paragraph(let runs) = blocks[0].block else {
            return XCTFail("expected a paragraph")
        }
        XCTAssertTrue(runs.contains {
            $0.text == "docs at https://example.com" && $0.style.link == "https://shidou.gg"
        })
        XCTAssertTrue(runs.contains {
            $0.text == "https://example.com/code" && $0.style.code && $0.style.link == nil
        })
    }

    func testTaskListMarkersLiftOutOfItemContent() {
        let blocks = MarkdownParser.parse("- [x] done\n- [ ] pending\n- plain\n")
        guard case .list(_, let items) = blocks[0].block else {
            return XCTFail("expected a list")
        }
        XCTAssertEqual(items.count, 3)
        XCTAssertEqual(items[0].checked, true)
        XCTAssertEqual(items[1].checked, false)
        XCTAssertNil(items[2].checked)
        XCTAssertEqual(text(items[0].blocks[0]), "done")
    }

    /// Tables were a named carry-over from the #9 prototype: the spike did not
    /// render them at all.
    func testTablesKeepAlignmentAndCells() {
        let blocks = MarkdownParser.parse(
            """
            | Left | Center | Right |
            |:-----|:------:|------:|
            | a    | b      | c     |
            """
        )
        guard case .table(let alignments, let header, let rows) = blocks[0].block else {
            return XCTFail("expected a table")
        }
        XCTAssertEqual(alignments, [.leading, .center, .trailing])
        XCTAssertEqual(header.map { $0.map(\.text).joined() }, ["Left", "Center", "Right"])
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].map { $0.map(\.text).joined() }, ["a", "b", "c"])
    }

    func testImagesSplitTheirParagraphAndKeepOrder() {
        let blocks = MarkdownParser.parse("before ![alt](shot.png) after")
        XCTAssertEqual(blocks.count, 3)
        XCTAssertEqual(text(blocks[0].block), "before ")
        guard case .image(let source, let alt) = blocks[1].block else {
            return XCTFail("expected an image block")
        }
        XCTAssertEqual(source, "shot.png")
        XCTAssertEqual(alt, "alt")
        XCTAssertEqual(text(blocks[2].block), " after")
    }

    func testSoftBreaksBecomeNewlinesInTheRun() {
        XCTAssertEqual(text(MarkdownParser.parse("first\nsecond")[0].block), "first\nsecond")
    }

    func testAnUnterminatedFenceIsNotClosed() {
        let blocks = MarkdownParser.parse("```swift\nlet x = 1\n")
        guard case .codeBlock(_, _, let closed) = blocks[0].block else {
            return XCTFail("expected a code block")
        }
        XCTAssertFalse(closed, "highlighting must wait for the closing fence")
    }

    func testOnlySettledExactMermaidFencesBecomeDiagrams() {
        let settled = MarkdownParser.parse("```mermaid\ngraph TD\n  A --> B\n```\n")
        XCTAssertEqual(settled.first?.block.settledMermaidSource, "graph TD\n  A --> B")

        let streaming = MarkdownParser.parse("```mermaid\ngraph TD\n  A --> B\n")
        XCTAssertNil(streaming.first?.block.settledMermaidSource)

        for language in ["Mermaid", "mermaid-js", "mermaid extra"] {
            let block = MarkdownBlock.codeBlock(
                language: language, code: "graph TD", fenceClosed: true
            )
            XCTAssertNil(block.settledMermaidSource, "\(language) must stay readable code")
        }
    }
}

/// The incremental path must agree with a full parse at every prefix — that
/// equality is the entire justification for the fast path.
final class IncrementalMarkdownTests: XCTestCase {
    private func blocks(_ incremental: IncrementalMarkdown) -> [MarkdownBlock] {
        incremental.canonicalBlocks.map(\.block)
    }

    private func assertMatchesFullParse(_ source: String, chunkSizes: [Int], line: UInt = #line) {
        for chunkSize in chunkSizes {
            let incremental = IncrementalMarkdown()
            var built = ""
            var characters = Array(source)
            var index = 0
            while index < characters.count {
                let end = min(index + chunkSize, characters.count)
                built += String(characters[index..<end])
                index = end
                incremental.setText(built)
                XCTAssertEqual(
                    blocks(incremental),
                    MarkdownParser.parse(built).map(\.block),
                    "divergence at \(built.count) characters with chunk size \(chunkSize)",
                    line: line
                )
            }
            characters = []
        }
    }

    func testIncrementalAppendsMatchFullParses() {
        assertMatchesFullParse(
            "# Heading\n\nA paragraph with **bold**.\n\n- one\n- two\n\n```js\nlet x = 1;\n```\n\nTail.",
            chunkSizes: [1, 3, 7, 64]
        )
    }

    /// A chunk boundary landing after the delimiter row must not settle a
    /// header-only table and strand the body rows in a trailing paragraph.
    func testStreamedTablesMatchFullParses() {
        assertMatchesFullParse(
            "Intro.\n\n| a | b |\n|---|---|\n| 1 | 2 |\n| 3 | 4 |\n\nAfter.",
            chunkSizes: [1, 4, 11]
        )
    }

    func testStreamedInlineImagesDoNotDuplicateBlocks() {
        assertMatchesFullParse("before ![alt](a.png) after\n\nnext", chunkSizes: [1, 5])
    }

    func testMultibyteContentSurvivesChunkedAppends() {
        assertMatchesFullParse("héllo 🎉 **wörld** — dash\n\nnext 🎉", chunkSizes: [1, 2, 6])
    }

    func testSetTextResetsOnARewrite() {
        let incremental = IncrementalMarkdown()
        incremental.setText("one\n\ntwo")
        incremental.setText("completely different")
        XCTAssertEqual(blocks(incremental), MarkdownParser.parse("completely different").map(\.block))
    }

    /// Link reference definitions resolve anywhere in the document, so the
    /// locality the fast path depends on no longer holds.
    func testLinkDefinitionsForceFullReparses() {
        assertMatchesFullParse(
            "[label]: https://example.com\n\nSee [label] for details.\n\nMore.",
            chunkSizes: [1, 9]
        )
    }

    func testDisplayBlocksCloseHangingEmphasisWhileStreaming() {
        let incremental = IncrementalMarkdown()
        incremental.setText("settled text\n\nnow **bold")

        guard case .paragraph(let runs) = incremental.displayBlocks(streaming: true).last?.block else {
            return XCTFail("expected a paragraph tail")
        }
        XCTAssertTrue(runs.contains { $0.text == "bold" && $0.style.bold })

        // The canonical tree is honest: the markers are still literal there.
        guard case .paragraph(let canonical) = incremental.canonicalBlocks.last?.block else {
            return XCTFail("expected a paragraph tail")
        }
        XCTAssertEqual(canonical.map(\.text).joined(), "now **bold")
    }

    func testDisplayBlocksLeaveCodeBlocksLiteral() {
        let incremental = IncrementalMarkdown()
        incremental.setText("```\nlet a = **b\n")
        guard case .codeBlock(_, let code, _) = incremental.displayBlocks(streaming: true).last?.block
        else {
            return XCTFail("expected a code block")
        }
        XCTAssertEqual(code, "let a = **b")
    }

    /// Settled blocks keep their identity across appends, which is what stops a
    /// LazyVStack from tearing down and rebuilding the whole transcript on
    /// every streamed chunk.
    func testSettledBlockIdentityIsStableAcrossAppends() {
        let incremental = IncrementalMarkdown()
        incremental.setText("first\n\nsecond\n\nthird\n\n")
        let before = incremental.canonicalBlocks.prefix(2).map(\.id)
        incremental.setText("first\n\nsecond\n\nthird\n\nfourth")
        XCTAssertEqual(Array(incremental.canonicalBlocks.prefix(2).map(\.id)), Array(before))
    }
}
