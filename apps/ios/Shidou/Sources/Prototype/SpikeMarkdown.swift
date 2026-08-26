// PROTOTYPE — streaming transcript spike (wayfinder #9). Throwaway.
//
// Incremental streaming markdown for one assistant message, approximating the
// desktop's stable-prefix scheme (`src/md/parser.rs`): the source splits into
// top-level segments at blank lines (fence-aware); all but the last two
// segments are settled — an append cannot change them — so their rendered
// blocks are cached and a delta re-parses only the tail. The tail segment is
// mended (SpikeMend) before the display parse. The real port would use
// swift-markdown's own source ranges instead of this line splitter.

import Markdown
import SwiftUI

// MARK: - Rendered blocks

enum SpikeBlock: Identifiable {
    case paragraph(id: Int, AttributedString)
    case heading(id: Int, level: Int, AttributedString)
    case codeBlock(id: Int, language: String?, code: String)
    case listItems(id: Int, ordered: Bool, [AttributedString])
    case quote(id: Int, AttributedString)
    case rule(id: Int)

    var id: Int {
        switch self {
        case .paragraph(let id, _), .heading(let id, _, _), .codeBlock(let id, _, _),
            .listItems(let id, _, _), .quote(let id, _), .rule(let id):
            return id
        }
    }
}

// MARK: - Incremental renderer

@MainActor
final class SpikeMarkdownRenderer {
    private struct Segment {
        var source: String
        var isFence: Bool
        var rendered: [SpikeBlock]
    }

    private(set) var source = ""
    private var segments: [Segment] = []
    /// Segments before this index cannot change on append (last two unsettled,
    /// mirroring the desktop's `settled_prefix`).
    private var stablePrefix = 0
    /// Monotonic block-id base per segment so LazyVStack identities stay
    /// stable for settled content.
    private var nextBlockId = 0

    func setText(_ text: String) {
        guard text != source else { return }
        if !source.isEmpty, text.hasPrefix(source) {
            append(String(text.dropFirst(source.count)))
        } else {
            reset(text)
        }
    }

    private func reset(_ text: String) {
        source = text
        segments = []
        nextBlockId = 0
        rebuildTail(from: text, replacingFrom: 0)
        stablePrefix = max(0, segments.count - 2)
    }

    private func append(_ delta: String) {
        guard !delta.isEmpty else { return }
        source += delta
        let boundarySource = segments[..<stablePrefix].map(\.source).joined()
        let tail = String(source.dropFirst(boundarySource.count))
        rebuildTail(from: tail, replacingFrom: stablePrefix)
        stablePrefix = max(0, segments.count - 2)
    }

    private func rebuildTail(from tailSource: String, replacingFrom index: Int) {
        segments.removeSubrange(index...)
        for raw in Self.splitTopLevel(tailSource) {
            let isFence = raw.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("```")
            segments.append(
                Segment(
                    source: raw,
                    isFence: isFence,
                    rendered: renderSegment(raw, mendTail: false)
                ))
        }
    }

    /// Blocks to display right now. Settled segments come from cache; the tail
    /// segment re-renders with hanging markers mended (unless it is a fence,
    /// whose content is literal).
    func displayBlocks(streaming: Bool) -> [SpikeBlock] {
        var blocks: [SpikeBlock] = []
        for (index, segment) in segments.enumerated() {
            let isTail = index == segments.count - 1
            if streaming, isTail, !segment.isFence,
                SpikeMend.closeHanging(segment.source) != nil
            {
                blocks.append(contentsOf: renderSegment(segment.source, mendTail: true))
            } else {
                blocks.append(contentsOf: segment.rendered)
            }
        }
        return blocks
    }

    // MARK: Parsing

    /// Split source into top-level segments at blank lines, keeping fenced
    /// code blocks (and their partial streaming tails) intact. Each segment
    /// retains its trailing blank lines so the joined segments reproduce the
    /// source byte-for-byte.
    static func splitTopLevel(_ source: String) -> [String] {
        var segments: [String] = []
        var current = ""
        var currentHasContent = false
        var inFence = false
        var line = Substring("")

        func flush() {
            if !current.isEmpty {
                segments.append(current)
                current = ""
                currentHasContent = false
            }
        }

        var rest = Substring(source)
        while !rest.isEmpty {
            if let newline = rest.firstIndex(of: "\n") {
                line = rest[...newline]
                rest = rest[rest.index(after: newline)...]
            } else {
                line = rest
                rest = Substring("")
            }
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("```") {
                inFence.toggle()
                current += line
                currentHasContent = true
                if !inFence { flush() }
                continue
            }
            if inFence {
                current += line
                continue
            }
            if trimmed.isEmpty {
                // Blank lines attach to the preceding segment, then close it.
                current += line
                if currentHasContent { flush() }
                continue
            }
            current += line
            currentHasContent = true
        }
        flush()
        return segments
    }

    private func renderSegment(_ raw: String, mendTail: Bool) -> [SpikeBlock] {
        var text = raw
        if mendTail, let mended = SpikeMend.closeHanging(raw) {
            text = mended
        }
        let document = Document(parsing: text)
        var blocks: [SpikeBlock] = []
        for child in document.children {
            if let block = renderBlock(child, id: nextBlockId + blocks.count) {
                blocks.append(block)
            }
        }
        if !mendTail {
            nextBlockId += blocks.count
        }
        return blocks
    }

    private func renderBlock(_ markup: Markup, id: Int) -> SpikeBlock? {
        switch markup {
        case let paragraph as Paragraph:
            return .paragraph(id: id, renderInline(paragraph.inlineChildren))
        case let heading as Heading:
            return .heading(id: id, level: heading.level, renderInline(heading.inlineChildren))
        case let code as CodeBlock:
            var body = code.code
            if body.hasSuffix("\n") { body.removeLast() }
            return .codeBlock(id: id, language: code.language, code: body)
        case let list as UnorderedList:
            return .listItems(id: id, ordered: false, list.listItems.map(renderListItem))
        case let list as OrderedList:
            return .listItems(id: id, ordered: true, list.listItems.map(renderListItem))
        case let quote as BlockQuote:
            var text = AttributedString()
            for (index, child) in quote.blockChildren.enumerated() {
                if index > 0 { text += AttributedString("\n") }
                if let paragraph = child as? Paragraph {
                    text += renderInline(paragraph.inlineChildren)
                } else {
                    text += AttributedString(child.format())
                }
            }
            return .quote(id: id, text)
        case is ThematicBreak:
            return .rule(id: id)
        default:
            let fallback = markup.format().trimmingCharacters(in: .whitespacesAndNewlines)
            guard !fallback.isEmpty else { return nil }
            return .paragraph(id: id, AttributedString(fallback))
        }
    }

    private func renderListItem(_ item: Markdown.ListItem) -> AttributedString {
        var text = AttributedString()
        for (index, child) in item.blockChildren.enumerated() {
            if index > 0 { text += AttributedString("\n") }
            if let paragraph = child as? Paragraph {
                text += renderInline(paragraph.inlineChildren)
            } else if let nested = child as? UnorderedList {
                for nestedItem in nested.listItems {
                    text += AttributedString("\n  • ") + renderListItem(nestedItem)
                }
            } else {
                text += AttributedString(child.format())
            }
        }
        return text
    }

    private struct InlineStyle {
        var bold = false
        var italic = false
        var code = false
        var strikethrough = false
        var link: String?
    }

    private func renderInline(_ children: some Sequence<InlineMarkup>) -> AttributedString {
        var out = AttributedString()
        for child in children {
            appendInline(child, style: InlineStyle(), into: &out)
        }
        return out
    }

    private func appendInline(_ markup: Markup, style: InlineStyle, into out: inout AttributedString) {
        switch markup {
        case let text as Markdown.Text:
            out += styled(text.string, style)
        case let code as InlineCode:
            var style = style
            style.code = true
            out += styled(code.code, style)
        case is SoftBreak, is Markdown.LineBreak:
            out += styled("\n", style)
        case let emphasis as Emphasis:
            var style = style
            style.italic = true
            for child in emphasis.children { appendInline(child, style: style, into: &out) }
        case let strong as Strong:
            var style = style
            style.bold = true
            for child in strong.children { appendInline(child, style: style, into: &out) }
        case let strike as Strikethrough:
            var style = style
            style.strikethrough = true
            for child in strike.children { appendInline(child, style: style, into: &out) }
        case let link as Markdown.Link:
            var style = style
            style.link = link.destination
            for child in link.children { appendInline(child, style: style, into: &out) }
        case let image as Markdown.Image:
            out += styled(image.plainText.isEmpty ? "[image]" : image.plainText, style)
        default:
            out += styled(markup.format(), style)
        }
    }

    private func styled(_ text: String, _ style: InlineStyle) -> AttributedString {
        var attributed = AttributedString(text)
        if style.code {
            attributed.font = .system(.body, design: .monospaced)
            attributed.backgroundColor = Color.primary.opacity(0.08)
        } else {
            var font = Font.body
            if style.bold { font = font.bold() }
            if style.italic { font = font.italic() }
            attributed.font = font
        }
        if style.strikethrough { attributed.strikethroughStyle = .single }
        if let link = style.link {
            if link != SpikeMend.pendingLinkURL, let url = URL(string: link) {
                attributed.link = url
            }
            attributed.foregroundColor = .accentColor
            attributed.underlineStyle = .single
        }
        return attributed
    }
}

// MARK: - Per-message renderer store

/// LazyVStack recreates row views as they scroll in and out, so renderers
/// live outside the view tree, keyed by message id. Settled messages keep
/// their final render cached forever.
@MainActor
final class SpikeMarkdownStore {
    private var renderers: [UUID: SpikeMarkdownRenderer] = [:]
    private var settled: [UUID: [SpikeBlock]] = [:]

    func blocks(for id: UUID, content: String, streaming: Bool) -> [SpikeBlock] {
        if !streaming, let cached = settled[id] { return cached }
        let renderer = renderers[id] ?? {
            let renderer = SpikeMarkdownRenderer()
            renderers[id] = renderer
            return renderer
        }()
        renderer.setText(content)
        let blocks = renderer.displayBlocks(streaming: streaming)
        if !streaming {
            settled[id] = blocks
            renderers[id] = nil
        }
        return blocks
    }

    func resetAll() {
        renderers = [:]
        settled = [:]
    }
}
