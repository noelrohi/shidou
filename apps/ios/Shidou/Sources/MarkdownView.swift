import ShidouMarkdown
import SwiftUI

/// Renders the parsed block tree. Everything here is layout and typography —
/// the parse, the mend and the highlight all happened before a frame started.
struct MarkdownBlocksView: View {
    let blocks: [TopBlock]
    let highlights: HighlightStore
    /// Resolves a link's destination and decides whether it is tappable at
    /// all; file links are inert until the Surfaces Sheet lands in slice ③.
    let onOpenLink: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(blocks) { top in
                MarkdownBlockView(
                    block: top.block, highlights: highlights, onOpenLink: onOpenLink
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct MarkdownBlockView: View {
    let block: MarkdownBlock
    let highlights: HighlightStore
    let onOpenLink: (String) -> Void

    var body: some View {
        switch block {
        case .paragraph(let runs):
            InlineRunsView(runs: runs, onOpenLink: onOpenLink)
        case .heading(let level, let runs):
            InlineRunsView(runs: runs, onOpenLink: onOpenLink)
                .font(headingFont(level))
                .accessibilityAddTraits(.isHeader)
                .padding(.top, level <= 2 ? 4 : 0)
        case .codeBlock(let language, let code, let fenceClosed):
            CodeBlockView(
                code: code, language: language, fenceClosed: fenceClosed, highlights: highlights
            )
        case .blockQuote(let children):
            HStack(alignment: .top, spacing: 10) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(.tertiary)
                    .frame(width: 3)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(children.enumerated()), id: \.offset) { _, child in
                        MarkdownBlockView(
                            block: child, highlights: highlights, onOpenLink: onOpenLink
                        )
                    }
                }
                .foregroundStyle(.secondary)
            }
        case .list(let start, let items):
            MarkdownListView(
                start: start, items: items, highlights: highlights, onOpenLink: onOpenLink
            )
        case .table(let alignments, let header, let rows):
            MarkdownTableView(
                alignments: alignments, header: header, rows: rows, onOpenLink: onOpenLink
            )
        case .thematicBreak:
            Divider()
        case .image(_, let alt):
            // Remote images live on the daemon host and load through the blob
            // path, which the Surfaces Sheet owns in slice ③. Until then the
            // alt text is what the transcript can honestly show.
            Label(alt.isEmpty ? "Image" : alt, systemImage: "photo")
                .font(.callout)
                .foregroundStyle(.secondary)
        case .html(let raw):
            Text(raw)
                .font(.system(.footnote, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
    }

    private func headingFont(_ level: Int) -> Font {
        switch level {
        case 1: return .title2.bold()
        case 2: return .title3.bold()
        case 3: return .headline
        default: return .subheadline.bold()
        }
    }
}

/// One paragraph's runs as a single `Text`, so the whole paragraph wraps as
/// one block rather than as a row of separately laid-out fragments.
struct InlineRunsView: View {
    let runs: [InlineRun]
    let onOpenLink: (String) -> Void

    @Environment(\.openURL) private var openURL

    var body: some View {
        Text(attributed)
            .textSelection(.enabled)
            .environment(\.openURL, OpenURLAction { url in
                onOpenLink(url.absoluteString)
                return .handled
            })
    }

    private var attributed: AttributedString {
        var out = AttributedString()
        for run in runs { out += styled(run) }
        return out
    }

    private func styled(_ run: InlineRun) -> AttributedString {
        var text = AttributedString(run.text)
        if run.style.code {
            text.font = .system(.body, design: .monospaced)
            text.backgroundColor = Color.primary.opacity(0.08)
        } else {
            var font = Font.body
            if run.style.bold { font = font.bold() }
            if run.style.italic { font = font.italic() }
            text.font = font
        }
        if run.style.strikethrough { text.strikethroughStyle = .single }
        if let link = run.style.link {
            // A link whose URL is still streaming is styled but not tappable:
            // the destination it would open is half a URL.
            if !run.style.isPendingLink, let url = URL(string: link) {
                text.link = url
            }
            text.foregroundColor = .accentColor
            text.underlineStyle = .single
        }
        return text
    }
}

private struct MarkdownListView: View {
    let start: Int?
    let items: [MarkdownListItem]
    let highlights: HighlightStore
    let onOpenLink: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    marker(index: index, item: item)
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(item.blocks.enumerated()), id: \.offset) { _, block in
                            MarkdownBlockView(
                                block: block, highlights: highlights, onOpenLink: onOpenLink
                            )
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func marker(index: Int, item: MarkdownListItem) -> some View {
        if let checked = item.checked {
            // A checkbox that is only a colour would say nothing to VoiceOver
            // and nothing to a user who cannot see it, so it is a glyph.
            Image(systemName: checked ? "checkmark.square.fill" : "square")
                .foregroundStyle(checked ? Color.accentColor : .secondary)
                .accessibilityLabel(checked ? "Done" : "Not done")
        } else if let start {
            Text("\(start + index).")
                .font(.body.monospacedDigit())
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
        } else {
            Text("•")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
        }
    }
}

/// Tables were a named carry-over from the #9 prototype, which did not render
/// them at all. A phone cannot give a wide table the width it wants, so it
/// scrolls horizontally rather than crushing every column to nothing.
private struct MarkdownTableView: View {
    let alignments: [TableAlignment]
    let header: [[InlineRun]]
    let rows: [[[InlineRun]]]
    let onOpenLink: (String) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 0) {
                row(header, isHeader: true)
                Divider()
                ForEach(Array(rows.enumerated()), id: \.offset) { index, cells in
                    row(cells, isHeader: false)
                    if index < rows.count - 1 { Divider().opacity(0.4) }
                }
            }
            .padding(10)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Table")
    }

    private func row(_ cells: [[InlineRun]], isHeader: Bool) -> some View {
        HStack(alignment: .top, spacing: 16) {
            ForEach(Array(cells.enumerated()), id: \.offset) { index, cell in
                InlineRunsView(runs: cell, onOpenLink: onOpenLink)
                    .font(isHeader ? .footnote.bold() : .footnote)
                    .multilineTextAlignment(textAlignment(index))
                    .frame(minWidth: 60, alignment: frameAlignment(index))
            }
        }
        .padding(.vertical, 5)
    }

    private func alignment(_ index: Int) -> TableAlignment {
        index < alignments.count ? alignments[index] : .leading
    }

    private func textAlignment(_ index: Int) -> TextAlignment {
        switch alignment(index) {
        case .leading: return .leading
        case .center: return .center
        case .trailing: return .trailing
        }
    }

    private func frameAlignment(_ index: Int) -> Alignment {
        switch alignment(index) {
        case .leading: return .leading
        case .center: return .center
        case .trailing: return .trailing
        }
    }
}

/// A fenced code block. Highlighting waits for the closing fence and runs off
/// the main thread; until it lands the code renders plain, which is the same
/// text in the same place.
private struct CodeBlockView: View {
    let code: String
    let language: String?
    let fenceClosed: Bool
    let highlights: HighlightStore

    @Environment(\.colorScheme) private var colorScheme
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            ScrollView(.horizontal, showsIndicators: false) {
                Text(attributed)
                    .font(.system(.footnote, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(10)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
        .task(id: highlightKey) {
            guard fenceClosed else { return }
            await highlights.load(code: code, language: language)
        }
    }

    private var highlightKey: String { "\(language ?? "")\u{1}\(fenceClosed)\u{1}\(code.count)" }

    @ViewBuilder
    private var header: some View {
        HStack {
            if let language, !language.isEmpty {
                Text(language)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Button {
                UIPasteboard.general.string = code
                copied = true
            } label: {
                Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                    .labelStyle(.iconOnly)
                    .font(.caption)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .accessibilityLabel(copied ? "Copied" : "Copy code")
            // The tap target is the whole corner, not the glyph.
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
        }
        .padding(.leading, 10)
        .padding(.trailing, 2)
        .padding(.top, 2)
    }

    private var attributed: AttributedString {
        guard fenceClosed, let spans = highlights.spans(code: code, language: language) else {
            return AttributedString(code)
        }
        var out = AttributedString()
        for span in spans {
            var text = AttributedString(span.text)
            text.foregroundColor = color(for: span.token)
            out += text
        }
        return out
    }

    /// Colours carry emphasis, never meaning: the same code reads correctly
    /// with every token plain, which is what an unhighlighted fence already is.
    private func color(for token: SyntaxToken) -> Color {
        switch token {
        case .plain: return .primary
        case .keyword: return colorScheme == .dark ? Color(red: 0.85, green: 0.60, blue: 0.95) : Color(red: 0.50, green: 0.16, blue: 0.62)
        case .string: return colorScheme == .dark ? Color(red: 0.62, green: 0.84, blue: 0.55) : Color(red: 0.13, green: 0.45, blue: 0.16)
        case .number: return colorScheme == .dark ? Color(red: 0.95, green: 0.72, blue: 0.44) : Color(red: 0.63, green: 0.36, blue: 0.05)
        case .comment: return .secondary
        case .type: return colorScheme == .dark ? Color(red: 0.50, green: 0.78, blue: 0.95) : Color(red: 0.09, green: 0.39, blue: 0.63)
        case .punctuation: return .secondary
        }
    }
}
