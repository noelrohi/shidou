import Foundation

// The block model the transcript renders, mirroring the desktop's
// `src/md/parser.rs` tree. It is deliberately free of SwiftUI: fonts, colours
// and layout are the view's business, and keeping them out is what lets the
// parse and the streaming contract be tested headlessly.

/// Inline styling threaded through nested emphasis and links.
public struct InlineStyle: Hashable, Sendable {
    public var bold = false
    public var italic = false
    public var code = false
    public var strikethrough = false
    /// Destination URL when inside a link.
    public var link: String?

    public init(
        bold: Bool = false,
        italic: Bool = false,
        code: Bool = false,
        strikethrough: Bool = false,
        link: String? = nil
    ) {
        self.bold = bold
        self.italic = italic
        self.code = code
        self.strikethrough = strikethrough
        self.link = link
    }

    /// A link whose URL is still streaming: styled like a link, never opened.
    public var isPendingLink: Bool { link == MarkdownMend.pendingLinkURL }
}

/// One run of identically styled inline text.
public struct InlineRun: Hashable, Sendable {
    public var text: String
    public var style: InlineStyle

    public init(text: String, style: InlineStyle = InlineStyle()) {
        self.text = text
        self.style = style
    }
}

/// Images interrupt a run of text rather than styling it, so they cannot be an
/// `InlineStyle` flag.
public enum InlinePiece: Hashable, Sendable {
    case run(InlineRun)
    case image(source: String?, alt: String)
}

/// GFM column alignment. Unspecified renders as `.leading`.
public enum TableAlignment: Sendable, Hashable {
    case leading
    case center
    case trailing
}

public struct MarkdownListItem: Hashable, Sendable {
    /// `nil` for an ordinary bullet; set for a GFM task-list checkbox.
    public var checked: Bool?
    public var blocks: [MarkdownBlock]

    public init(checked: Bool? = nil, blocks: [MarkdownBlock]) {
        self.checked = checked
        self.blocks = blocks
    }
}

public indirect enum MarkdownBlock: Hashable, Sendable {
    case paragraph([InlineRun])
    case heading(level: Int, runs: [InlineRun])
    /// `fenceClosed` is false only for the still-streaming final fence, which
    /// is the signal the renderer uses to defer syntax highlighting.
    case codeBlock(language: String?, code: String, fenceClosed: Bool)
    case blockQuote([MarkdownBlock])
    case list(start: Int?, items: [MarkdownListItem])
    case table(alignments: [TableAlignment], header: [[InlineRun]], rows: [[[InlineRun]]])
    case thematicBreak
    /// A standalone image. Inline images split their paragraph so the text
    /// before and after keeps its order around them.
    case image(source: String?, alt: String)
    case html(String)

    /// Source for a complete fence whose info string is exactly `mermaid`.
    /// Aliases and additional info remain ordinary readable code blocks.
    public var settledMermaidSource: String? {
        guard case .codeBlock(let language, let code, let fenceClosed) = self,
            language == "mermaid", fenceClosed
        else { return nil }
        return code
    }
}

/// A top-level block plus the UTF-8 byte range of the source it came from.
/// The range is what makes incremental appends possible, and what lets a code
/// block ask whether its fence has closed.
public struct TopBlock: Hashable, Sendable, Identifiable {
    /// Position in the document. Settled blocks keep theirs across appends, so
    /// it is a stable `ForEach` identity for everything but the streaming tail.
    public var id: Int
    public var block: MarkdownBlock
    public var range: Range<Int>

    public init(id: Int, block: MarkdownBlock, range: Range<Int>) {
        self.id = id
        self.block = block
        self.range = range
    }
}
