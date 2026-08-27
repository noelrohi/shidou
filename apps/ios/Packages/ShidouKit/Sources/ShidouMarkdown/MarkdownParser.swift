import Foundation
import Markdown

// Block-level parsing over `apple/swift-markdown`, ported from the desktop's
// `src/md/parser.rs`.
//
// Every top-level block is paired with its UTF-8 byte range in the source.
// swift-markdown reports ranges as line/column pairs whose columns count UTF-8
// bytes, so one pass over the line starts converts them; the ranges are what
// `IncrementalMarkdown` uses to reparse only a streamed tail.

public enum MarkdownParser {
    /// Parse a whole source into top-level blocks with their source ranges.
    public static func parse(_ source: String) -> [TopBlock] {
        let document = Document(parsing: source)
        let offsets = LineOffsets(source)
        let bytes = source.utf8.count
        var blocks: [TopBlock] = []
        for child in document.children {
            let range = offsets.byteRange(of: child.range, limit: bytes)
            for block in topLevelBlocks(child, source: source, range: range) {
                blocks.append(TopBlock(id: blocks.count, block: block, range: range))
            }
        }
        return blocks
    }

    /// A paragraph split around an inline image yields several blocks that
    /// share one source range; everything else yields exactly one.
    private static func topLevelBlocks(
        _ markup: Markup,
        source: String,
        range: Range<Int>
    ) -> [MarkdownBlock] {
        if let paragraph = markup as? Paragraph {
            return piecesIntoBlocks(inlinePieces(paragraph.inlineChildren, style: InlineStyle()))
        }
        guard let block = self.block(markup, source: source, range: range) else { return [] }
        return [block]
    }

    static func block(_ markup: Markup, source: String, range: Range<Int>) -> MarkdownBlock? {
        switch markup {
        case let paragraph as Paragraph:
            return .paragraph(runs(paragraph.inlineChildren))
        case let heading as Heading:
            return .heading(level: heading.level, runs: runs(heading.inlineChildren))
        case let code as CodeBlock:
            var body = code.code
            if body.hasSuffix("\n") { body.removeLast() }
            return .codeBlock(
                language: code.language?.trimmed(),
                code: body,
                fenceClosed: fenceIsClosed(source: source, range: range)
            )
        case let quote as BlockQuote:
            return .blockQuote(childBlocks(quote, source: source))
        case let list as UnorderedList:
            return .list(start: nil, items: listItems(list.listItems, source: source))
        case let list as OrderedList:
            return .list(
                start: Int(list.startIndex), items: listItems(list.listItems, source: source)
            )
        case let table as Markdown.Table:
            return self.table(table)
        case is ThematicBreak:
            return .thematicBreak
        case let html as HTMLBlock:
            return .html(html.rawHTML.trimmingCharacters(in: .whitespacesAndNewlines))
        default:
            // Unknown containers are transparent: their children splice in, so
            // a construct this build does not model still shows its content.
            let children = childBlocks(markup, source: source)
            if children.count == 1 { return children[0] }
            return children.isEmpty ? nil : .blockQuote(children)
        }
    }

    private static func childBlocks(_ markup: Markup, source: String) -> [MarkdownBlock] {
        let offsets = LineOffsets(source)
        let bytes = source.utf8.count
        var blocks: [MarkdownBlock] = []
        for child in markup.children {
            let range = offsets.byteRange(of: child.range, limit: bytes)
            if let paragraph = child as? Paragraph {
                blocks.append(
                    contentsOf: piecesIntoBlocks(
                        inlinePieces(paragraph.inlineChildren, style: InlineStyle())
                    )
                )
                continue
            }
            if let block = block(child, source: source, range: range) { blocks.append(block) }
        }
        return blocks
    }

    private static func listItems(
        _ items: some Sequence<Markdown.ListItem>,
        source: String
    ) -> [MarkdownListItem] {
        items.map { item in
            MarkdownListItem(
                checked: item.checkbox.map { $0 == .checked },
                blocks: childBlocks(item, source: source)
            )
        }
    }

    private static func table(_ table: Markdown.Table) -> MarkdownBlock {
        let alignments = table.columnAlignments.map { alignment -> TableAlignment in
            switch alignment {
            case .center: return .center
            case .right: return .trailing
            case .left, .none: return .leading
            }
        }
        let header = Array(table.head.cells).map { runs($0.inlineChildren) }
        let rows = Array(table.body.rows).map { row in
            Array(row.cells).map { runs($0.inlineChildren) }
        }
        return .table(alignments: alignments, header: header, rows: rows)
    }

    // MARK: - Inline

    static func runs(_ children: some Sequence<InlineMarkup>) -> [InlineRun] {
        piecesIntoRuns(inlinePieces(children, style: InlineStyle()))
    }

    private static func piecesIntoRuns(_ pieces: [InlinePiece]) -> [InlineRun] {
        pieces.compactMap { piece in
            switch piece {
            case .run(let run):
                return run
            case .image(_, let alt):
                // Nothing here can host a block-level image, so it degrades to
                // its alt text rather than disappearing.
                return alt.isEmpty ? nil : InlineRun(text: alt)
            }
        }
    }

    /// Images become their own block and the text around them keeps its order.
    private static func piecesIntoBlocks(_ pieces: [InlinePiece]) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        var runs: [InlineRun] = []
        for piece in pieces {
            switch piece {
            case .run(let run):
                runs.append(run)
            case .image(let source, let alt):
                if !runs.isEmpty {
                    blocks.append(.paragraph(runs))
                    runs = []
                }
                blocks.append(.image(source: source, alt: alt))
            }
        }
        if !runs.isEmpty { blocks.append(.paragraph(runs)) }
        return blocks.isEmpty ? [.paragraph([])] : blocks
    }

    private static func inlinePieces(
        _ children: some Sequence<InlineMarkup>,
        style: InlineStyle
    ) -> [InlinePiece] {
        var pieces: [InlinePiece] = []
        for child in children { append(child, style: style, into: &pieces) }
        return linkifyBareURLs(merge(pieces))
    }

    private static func append(_ markup: Markup, style: InlineStyle, into pieces: inout [InlinePiece]) {
        switch markup {
        case let text as Markdown.Text:
            pieces.append(.run(InlineRun(text: text.string, style: style)))
        case let code as InlineCode:
            var style = style
            style.code = true
            pieces.append(.run(InlineRun(text: code.code, style: style)))
        case is SoftBreak:
            // The desktop renderer keeps the author's line break rather than
            // reflowing, and the two transcripts must wrap the same way.
            pieces.append(.run(InlineRun(text: "\n", style: style)))
        case is Markdown.LineBreak:
            pieces.append(.run(InlineRun(text: "\n", style: style)))
        case let emphasis as Emphasis:
            var style = style
            style.italic = true
            for child in emphasis.children { append(child, style: style, into: &pieces) }
        case let strong as Strong:
            var style = style
            style.bold = true
            for child in strong.children { append(child, style: style, into: &pieces) }
        case let strike as Strikethrough:
            var style = style
            style.strikethrough = true
            for child in strike.children { append(child, style: style, into: &pieces) }
        case let link as Markdown.Link:
            var style = style
            style.link = link.destination
            for child in link.children { append(child, style: style, into: &pieces) }
        case let image as Markdown.Image:
            pieces.append(.image(source: image.source, alt: image.plainText))
        case let html as InlineHTML:
            pieces.append(.run(InlineRun(text: html.rawHTML, style: style)))
        default:
            let text = markup.format()
            if !text.isEmpty { pieces.append(.run(InlineRun(text: text, style: style))) }
        }
    }

    /// Coalesce neighbouring runs that share a style, leaving images in place.
    /// Linkification needs whole words, and swift-markdown can split ordinary
    /// text at punctuation that might have opened emphasis.
    private static func merge(_ pieces: [InlinePiece]) -> [InlinePiece] {
        var merged: [InlinePiece] = []
        for piece in pieces {
            guard case .run(let run) = piece else {
                merged.append(piece)
                continue
            }
            if case .run(let previous) = merged.last, previous.style == run.style {
                merged[merged.count - 1] = .run(
                    InlineRun(text: previous.text + run.text, style: run.style)
                )
                continue
            }
            merged.append(piece)
        }
        return merged
    }

    /// CommonMark only recognizes angle-bracket autolinks. Transcript content
    /// is conversational, so a bare `https://…` should be useful without the
    /// author having written it as a link.
    private static func linkifyBareURLs(_ pieces: [InlinePiece]) -> [InlinePiece] {
        var out: [InlinePiece] = []
        for piece in pieces {
            guard case .run(let run) = piece, run.style.link == nil, !run.style.code else {
                out.append(piece)
                continue
            }
            out.append(contentsOf: BareURLScanner.split(run).map(InlinePiece.run))
        }
        return out
    }

    // MARK: - Fences

    /// Whether a code block's closing fence has arrived. Indented code blocks
    /// have no fence to close, so they count as closed the moment they parse.
    static func fenceIsClosed(source: String, range: Range<Int>) -> Bool {
        let bytes = Array(source.utf8)
        guard range.lowerBound < bytes.count else { return true }
        let slice = Array(bytes[range.lowerBound..<min(range.upperBound, bytes.count)])
        guard let text = String(bytes: slice, encoding: .utf8) else { return true }
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        while lines.last?.trimmingCharacters(in: .whitespaces).isEmpty == true { lines.removeLast() }
        guard let opening = lines.first?.trimmingCharacters(in: .whitespaces),
            let marker = opening.first, marker == "`" || marker == "~"
        else {
            return true
        }
        let openRun = opening.prefix { $0 == marker }.count
        guard openRun >= 3, lines.count > 1 else { return false }
        let last = lines[lines.count - 1].trimmingCharacters(in: .whitespaces)
        guard last.allSatisfy({ $0 == marker }) else { return false }
        return last.count >= openRun
    }
}

// MARK: - Source offsets

/// UTF-8 byte offset of the start of each line, so swift-markdown's
/// line/column ranges convert without rescanning the source per block.
struct LineOffsets {
    private let starts: [Int]
    private let total: Int

    init(_ source: String) {
        var starts = [0]
        var offset = 0
        for byte in source.utf8 {
            offset += 1
            if byte == UInt8(ascii: "\n") { starts.append(offset) }
        }
        self.starts = starts
        self.total = offset
    }

    func byteOffset(_ location: SourceLocation) -> Int {
        let line = location.line - 1
        guard line >= 0, line < starts.count else { return total }
        return min(total, starts[line] + max(0, location.column - 1))
    }

    /// A block with no reported range covers nothing, which is harmless: only
    /// the incremental parser reads ranges, and it treats an empty tail range
    /// as "reparse from here".
    func byteRange(of range: SourceRange?, limit: Int) -> Range<Int> {
        guard let range else { return limit..<limit }
        let lower = min(byteOffset(range.lowerBound), limit)
        let upper = min(max(byteOffset(range.upperBound), lower), limit)
        return lower..<upper
    }
}

extension String {
    fileprivate func trimmed() -> String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
