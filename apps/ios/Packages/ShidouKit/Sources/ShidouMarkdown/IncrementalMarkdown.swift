import Foundation

/// Incremental markdown for one streaming message, ported from the desktop's
/// `IncrementalParser` in `src/md/parser.rs`.
///
/// Appending to markdown cannot change anything before the start of the
/// second-to-last top-level block, so a delta reparses only from there: a
/// streamed response costs O(delta + last two blocks) per chunk instead of
/// O(document). At 120 tokens per second over a long turn that is the
/// difference between a smooth transcript and one that reparses the whole
/// answer thirty times a second.
///
/// The display tree additionally mends the final block's hanging inline
/// markers (`MarkdownMend`) so styling settles as content arrives rather than
/// flipping when the closer does. Only the display parse sees mended text.
public final class IncrementalMarkdown {
    public private(set) var source = ""

    private var blocks: [TopBlock] = []
    /// Index of the first block an append could still change.
    private var stablePrefix = 0
    /// Link reference definitions (`[label]: url`) resolve non-locally, so a
    /// source containing one gives up locality and reparses whole.
    private var fullReparseOnly = false
    /// Source after the last newline. A definition can arrive one character at
    /// a time, so the scan has to see the whole line the delta lands in — and
    /// only that line, or the check would cost O(document) per chunk.
    private var pendingLine = ""

    public init() {}

    /// The canonical tree — what the message settles to. The tail may still be
    /// mid-marker; `displayBlocks(streaming:)` is what the view renders.
    public var canonicalBlocks: [TopBlock] { blocks }

    /// Point the parser at `text`. Appends reparse incrementally; any other
    /// change falls back to a full reparse.
    public func setText(_ text: String) {
        guard text != source else { return }
        if !source.isEmpty, !fullReparseOnly, text.hasPrefix(source) {
            append(String(text.dropFirst(source.count)))
        } else {
            reset(text)
        }
    }

    public func reset(_ text: String) {
        source = text
        blocks = MarkdownParser.parse(text)
        fullReparseOnly = Self.hasLinkDefinition(text)
        pendingLine = Self.lastLine(of: text)
        stablePrefix = settledPrefix()
    }

    private func append(_ delta: String) {
        guard !delta.isEmpty else { return }
        if Self.hasLinkDefinition(pendingLine + delta) {
            reset(source + delta)
            return
        }
        // With no blocks yet there is no settled prefix to preserve, and the
        // source is not necessarily empty: a lone link reference definition
        // parses to nothing at all, and resuming past it would drop it.
        let boundary: Int
        if stablePrefix < blocks.count {
            boundary = blocks[stablePrefix].range.lowerBound
        } else {
            boundary = blocks.isEmpty ? 0 : source.utf8.count
        }
        source += delta
        pendingLine = Self.lastLine(of: pendingLine + delta)
        guard let tailSource = Self.substring(source, fromByteOffset: boundary) else {
            reset(source)
            return
        }
        blocks.removeSubrange(stablePrefix...)
        for var block in MarkdownParser.parse(tailSource) {
            block.id = blocks.count
            block.range = (block.range.lowerBound + boundary)..<(block.range.upperBound + boundary)
            blocks.append(block)
        }
        stablePrefix = settledPrefix()
    }

    /// Blocks as they should be displayed right now. While streaming, the
    /// final block is re-derived from mended source; everything before it is
    /// the cached canonical parse, untouched.
    public func displayBlocks(streaming: Bool) -> [TopBlock] {
        guard streaming, let tail = displayTail() else { return blocks }
        return Array(blocks.dropLast()) + tail
    }

    /// Replacement blocks for the final block while streaming. `nil` means the
    /// canonical tree already renders correctly — the common case, and the one
    /// worth making free.
    private func displayTail() -> [TopBlock]? {
        guard let last = blocks.last else { return nil }
        // A code block's content is literal: mending would corrupt it, and a
        // half-typed fence must not be reinterpreted.
        if case .codeBlock = last.block { return nil }
        guard let tailSource = Self.substring(source, fromByteOffset: last.range.lowerBound),
            let mended = MarkdownMend.closeHanging(tailSource)
        else {
            return nil
        }
        let offset = last.range.lowerBound
        let limit = source.utf8.count
        return MarkdownParser.parse(mended).enumerated().map { index, block in
            let lower = min(block.range.lowerBound + offset, limit)
            let upper = min(max(block.range.upperBound + offset, lower), limit)
            return TopBlock(id: last.id + index, block: block.block, range: lower..<upper)
        }
    }

    /// Appending mostly only extends the final block, but two cases reach
    /// further back, so the last *two* source-level groups stay unsettled:
    ///
    /// - A GFM table absorbs the line after it once that line becomes a valid
    ///   row, yet a partial row of just `|` transiently parses as its own
    ///   paragraph. Settling the table then would strand every later row in
    ///   that paragraph.
    /// - A paragraph split around an inline image yields several blocks that
    ///   share one source range; they must settle and reparse as a unit or the
    ///   pieces before the image get re-emitted on the next append.
    private func settledPrefix() -> Int {
        var index = blocks.count
        for _ in 0..<2 {
            guard index > 0 else { break }
            let groupStart = blocks[index - 1].range.lowerBound
            while index > 0, blocks[index - 1].range.lowerBound == groupStart { index -= 1 }
        }
        return index
    }

    /// Cheap scan for a link reference definition, which resolves references
    /// anywhere in the document and so breaks locality.
    private static func hasLinkDefinition(_ text: String) -> Bool {
        text.split(separator: "\n", omittingEmptySubsequences: false).contains { line in
            let line = line.drop { $0 == " " || $0 == "\t" }
            guard line.first == "[" else { return false }
            guard let end = line.range(of: "]:") else { return false }
            return end.lowerBound > line.index(after: line.startIndex)
        }
    }

    private static func lastLine(of text: String) -> String {
        guard let newline = text.lastIndex(of: "\n") else { return text }
        return String(text[text.index(after: newline)...])
    }

    private static func substring(_ text: String, fromByteOffset offset: Int) -> String? {
        guard offset > 0 else { return text }
        let utf8 = text.utf8
        guard offset <= utf8.count else { return nil }
        let start = utf8.index(utf8.startIndex, offsetBy: offset)
        return String(utf8[start...])
    }
}
