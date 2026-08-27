import XCTest

@testable import ShidouMarkdown

/// Mirrors the desktop's `src/md/mend.rs` tests case for case. The two
/// implementations have to agree: the same response streamed to a Mac and to a
/// phone should settle to the same styling at the same moment.
final class MarkdownMendTests: XCTestCase {
    private let pending = MarkdownMend.pendingLinkURL

    func testSettledTextNeedsNoRepair() {
        for text in [
            "plain text",
            "**bold** and *em* and `code`",
            "~~struck~~ through",
            "[link](https://example.com) done",
            "a * b * c",
            "",
        ] {
            XCTAssertNil(MarkdownMend.closeHanging(text), "unexpected repair for \(text)")
        }
    }

    func testClosesHangingEmphasis() {
        XCTAssertEqual(MarkdownMend.closeHanging("now **bold"), "now **bold**")
        XCTAssertEqual(MarkdownMend.closeHanging("an *em"), "an *em*")
        XCTAssertEqual(MarkdownMend.closeHanging("an _em"), "an _em_")
        XCTAssertEqual(MarkdownMend.closeHanging("__strong"), "__strong__")
        XCTAssertEqual(MarkdownMend.closeHanging("~~struck"), "~~struck~~")
    }

    func testClosesNestedEmphasisInnermostFirst() {
        XCTAssertEqual(MarkdownMend.closeHanging("**bold *both"), "**bold *both***")
    }

    func testCompletesAHalfStreamedCloser() {
        XCTAssertEqual(MarkdownMend.closeHanging("**bold*"), "**bold**")
    }

    /// Nothing to style yet, so the markers must remain as typed.
    func testOpenersWithoutContentStayLiteral() {
        XCTAssertNil(MarkdownMend.closeHanging("text **"))
        XCTAssertNil(MarkdownMend.closeHanging("text ** "))
    }

    func testClosesHangingInlineCode() {
        XCTAssertEqual(MarkdownMend.closeHanging("call `foo"), "call `foo`")
        XCTAssertEqual(MarkdownMend.closeHanging("call ``a`b"), "call ``a`b``")
        XCTAssertNil(MarkdownMend.closeHanging("call `"))
    }

    func testEmphasisInsideInlineCodeIsLiteral() {
        XCTAssertNil(MarkdownMend.closeHanging("`a ** b`"))
    }

    func testMendsLinksWhoseURLIsStillStreaming() {
        XCTAssertEqual(
            MarkdownMend.closeHanging("see [docs](https://exa"), "see [docs](\(pending))"
        )
        XCTAssertEqual(MarkdownMend.closeHanging("see [docs"), "see [docs](\(pending))")
        XCTAssertNil(MarkdownMend.closeHanging("see ["))
    }

    func testEmphasisInsideAStreamingLinkTextClosesFirst() {
        XCTAssertEqual(
            MarkdownMend.closeHanging("see [**docs"), "see [**docs**](\(pending))"
        )
    }

    func testEscapesKeepMarkersLiteral() {
        XCTAssertNil(MarkdownMend.closeHanging(#"literal \*star"#))
    }

    func testDefusesAStreamingSetextUnderline() {
        XCTAssertEqual(MarkdownMend.closeHanging("paragraph\n-"), "paragraph\n-\u{200B}")
        // A blank line between means it is a list bullet, not an underline.
        XCTAssertNil(MarkdownMend.closeHanging("paragraph\n\n-"))
        // A settled line break is already unambiguous.
        XCTAssertNil(MarkdownMend.closeHanging("paragraph\n-\n"))
    }

    /// The scanner runs on every delta, so robustness beats precision: no
    /// prefix may trap, and one pass must leave nothing hanging or a streamed
    /// response would grow markers on every chunk.
    func testEveryPrefixOfACorpusMendsAndConverges() {
        let corpus = """
            Mixed **bold `code`** and *em*, a [link](https://example.com), \
            ~~struck~~, emoji 🎉, accents héllo, and a list:

            - one
            - two

            """
        let characters = Array(corpus)
        for end in 0...characters.count {
            let prefix = String(characters[..<end])
            guard let mended = MarkdownMend.closeHanging(prefix) else { continue }
            XCTAssertTrue(
                mended.count >= prefix.count || mended.hasSuffix("(\(pending))"),
                "mending \(prefix) shrank it to \(mended)"
            )
            XCTAssertNil(
                MarkdownMend.closeHanging(mended),
                "mending \(prefix) into \(mended) left work behind"
            )
        }
    }
}
