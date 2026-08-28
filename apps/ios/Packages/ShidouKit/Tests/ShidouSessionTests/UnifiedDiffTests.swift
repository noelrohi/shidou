import XCTest

@testable import ShidouSession

/// The desktop and the web client both parse patches with a library the phone
/// cannot use (`@pierre/diffs` is TypeScript), so this parser is the one place
/// where a diff becomes rows. It gets its own tests for the same reason a wire
/// decoder does: everything downstream trusts it, and a patch is the one input
/// that arrives verbatim from `git`.
final class UnifiedDiffTests: XCTestCase {
    private let singleFile = """
        diff --git a/src/limiter.rs b/src/limiter.rs
        index 338d5c3..d8d1258 100644
        --- a/src/limiter.rs
        +++ b/src/limiter.rs
        @@ -7,7 +7,7 @@ use std::time::{Duration, Instant};
         const BURST: f64 = 20.0;
        -/// Buckets refill in whole-second steps.
        -const REFILL_INTERVAL: Duration = Duration::from_secs(1);
        +/// Sustained requests per second once the burst is spent.
        +const REFILL_PER_SECOND: f64 = 5.0;

         #[derive(Clone, Copy)]

        """

    func testParsesOneFileIntoHunksAndLineNumbers() throws {
        let files = UnifiedDiff.parse(singleFile)
        XCTAssertEqual(files.count, 1)
        let file = try XCTUnwrap(files.first)
        XCTAssertEqual(file.path, "src/limiter.rs")
        XCTAssertEqual(file.previousPath, nil)
        XCTAssertEqual(file.change, .modified)
        XCTAssertEqual(file.additions, 2)
        XCTAssertEqual(file.deletions, 2)

        let hunk = try XCTUnwrap(file.hunks.first)
        XCTAssertEqual(hunk.header, "@@ -7,7 +7,7 @@ use std::time::{Duration, Instant};")
        XCTAssertEqual(hunk.lines.count, 7)

        // The first context line sits at line 7 on both sides.
        XCTAssertEqual(hunk.lines[0].kind, .context)
        XCTAssertEqual(hunk.lines[0].oldNumber, 7)
        XCTAssertEqual(hunk.lines[0].newNumber, 7)

        // Deletions number only on the left, additions only on the right.
        XCTAssertEqual(hunk.lines[1].kind, .deletion)
        XCTAssertEqual(hunk.lines[1].oldNumber, 8)
        XCTAssertNil(hunk.lines[1].newNumber)
        XCTAssertEqual(hunk.lines[3].kind, .addition)
        XCTAssertNil(hunk.lines[3].oldNumber)
        XCTAssertEqual(hunk.lines[3].newNumber, 8)

        // The leading marker is not part of the content.
        XCTAssertEqual(hunk.lines[3].content, "/// Sustained requests per second once the burst is spent.")

        // A bare empty line inside a hunk is a context line `git` wrote
        // without its leading space; dropping it would shift every number
        // after it.
        XCTAssertEqual(hunk.lines[5].kind, .context)
        XCTAssertEqual(hunk.lines[5].content, "")
        XCTAssertEqual(hunk.lines[6].oldNumber, 11)
        XCTAssertEqual(hunk.lines[6].newNumber, 11)
    }

    func testSplitsAMultiFilePatchAndReadsEachHeader() throws {
        let patch = """
            diff --git a/a.txt b/a.txt
            new file mode 100644
            index 0000000..b6fc4c6
            --- /dev/null
            +++ b/a.txt
            @@ -0,0 +1,1 @@
            +hello
            diff --git a/gone.txt b/gone.txt
            deleted file mode 100644
            index b6fc4c6..0000000
            --- a/gone.txt
            +++ /dev/null
            @@ -1,1 +0,0 @@
            -bye
            diff --git a/old.txt b/new.txt
            similarity index 92%
            rename from old.txt
            rename to new.txt
            index 1234567..89abcde 100644
            --- a/old.txt
            +++ b/new.txt
            @@ -1,1 +1,1 @@
            -before
            +after
            diff --git a/logo.png b/logo.png
            index 1111111..2222222 100644
            Binary files a/logo.png and b/logo.png differ
            """
        let files = UnifiedDiff.parse(patch)
        XCTAssertEqual(files.map(\.path), ["a.txt", "gone.txt", "new.txt", "logo.png"])
        XCTAssertEqual(files[0].change, .added)
        XCTAssertEqual(files[0].additions, 1)
        XCTAssertEqual(files[1].change, .deleted)
        XCTAssertEqual(files[1].deletions, 1)
        XCTAssertEqual(files[2].change, .renamed)
        XCTAssertEqual(files[2].previousPath, "old.txt")
        XCTAssertEqual(files[3].change, .binary)
        XCTAssertTrue(files[3].hunks.isEmpty)
    }

    /// Quoted paths appear whenever a name has a space or a non-ASCII byte,
    /// and a parser that keeps the quotes shows the user a filename that does
    /// not exist.
    func testUnquotesPathsWithSpaces() throws {
        let patch = """
            diff --git "a/src/my file.txt" "b/src/my file.txt"
            --- "a/src/my file.txt"
            +++ "b/src/my file.txt"
            @@ -1 +1 @@
            -a
            +b
            """
        XCTAssertEqual(UnifiedDiff.parse(patch).first?.path, "src/my file.txt")
    }

    /// `\\ No newline at end of file` is metadata about the line above it, not
    /// a line of its own — counting it would inflate the diff stat.
    func testIgnoresTheNoNewlineMarker() throws {
        let patch = """
            diff --git a/a.txt b/a.txt
            --- a/a.txt
            +++ b/a.txt
            @@ -1 +1 @@
            -a
            \\ No newline at end of file
            +b
            """
        let file = try XCTUnwrap(UnifiedDiff.parse(patch).first)
        XCTAssertEqual(file.additions, 1)
        XCTAssertEqual(file.deletions, 1)
        XCTAssertEqual(file.hunks.first?.lines.count, 2)
    }

    func testHunksWithoutCountsDefaultToOneLine() throws {
        let patch = """
            diff --git a/a.txt b/a.txt
            --- a/a.txt
            +++ b/a.txt
            @@ -3 +3 @@
            -a
            +b
            """
        let hunk = try XCTUnwrap(UnifiedDiff.parse(patch).first?.hunks.first)
        XCTAssertEqual(hunk.lines[0].oldNumber, 3)
        XCTAssertEqual(hunk.lines[1].newNumber, 3)
    }

    func testEmptyPatchProducesNoFiles() {
        XCTAssertTrue(UnifiedDiff.parse("").isEmpty)
        XCTAssertTrue(UnifiedDiff.parse("\n\n").isEmpty)
    }

    /// The file list shows a stat per row, so the totals have to come from the
    /// same parse the detail view renders — not from `numstat`, which the
    /// daemon computes separately and which is absent for a turn diff.
    func testTotalsSumEveryFile() {
        let files = UnifiedDiff.parse(singleFile)
        XCTAssertEqual(UnifiedDiff.additions(files), 2)
        XCTAssertEqual(UnifiedDiff.deletions(files), 2)
    }
}
