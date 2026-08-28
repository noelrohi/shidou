import ShidouMarkdown
import ShidouProtocol
import ShidouSession
import SwiftUI

/// The workspace tree, read-only.
///
/// Editing is deferred past v1 by the parity cut, so nothing here writes —
/// and the surface says so rather than showing a disabled pencil, because a
/// control that can never work is worse than no control.
struct FileTreeView: View {
    let surfaces: WorkspaceSurfaces

    var body: some View {
        List {
            ForEach(surfaces.tree) { entry in
                row(entry)
            }
        }
        .listStyle(.plain)
        .surfaceState(
            isEmpty: surfaces.tree.isEmpty,
            isLoading: surfaces.isLoadingTree,
            error: surfaces.treeError,
            hasLoaded: surfaces.hasLoadedTree,
            retry: { surfaces.loadTree(force: true) },
            failureTitle: "Could not read the workspace",
            failureIcon: "folder.badge.gearshape"
        ) {
            ContentUnavailableView(
                "Nothing here", systemImage: "folder",
                description: Text("This directory is empty."))
        }
        .navigationTitle("Files")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { surfaces.loadTree(force: true) }
        .task { surfaces.loadTree() }
    }

    @ViewBuilder
    private func row(_ entry: WorkingTreeEntry) -> some View {
        if entry.isDir {
            Button {
                surfaces.toggle(entry)
            } label: {
                TreeRowLabel(entry: entry, expanded: surfaces.isExpanded(entry))
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(.isButton)
            .accessibilityHint(
                surfaces.isExpanded(entry)
                    ? Text("Collapses this folder") : Text("Expands this folder"))
        } else {
            NavigationLink(
                value: SurfaceRoute.file(path: WorkspaceRelativePath(entry.relativePath), line: nil)
            ) {
                TreeRowLabel(entry: entry, expanded: false)
            }
        }
    }
}

private struct TreeRowLabel: View {
    let entry: WorkingTreeEntry
    let expanded: Bool

    var body: some View {
        HStack(spacing: 6) {
            // Depth is the daemon's own, so an expanded subtree indents the
            // same way it does on the desktop.
            Color.clear.frame(width: CGFloat(entry.depth) * 14, height: 1)
            Image(systemName: symbol)
                .font(.footnote)
                .foregroundStyle(entry.isDir ? Color.accentColor : Color.secondary)
                .frame(width: 18)
                .accessibilityHidden(true)
            Text(verbatim: entry.name)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
            if let status = entry.status {
                // Status is a letter as well as a colour: a working-copy state
                // that only exists as a tint is invisible to half its readers.
                Text(verbatim: statusLetter(status))
                    .font(.caption2.bold().monospaced())
                    .foregroundStyle(status == .untracked ? Color.green : Color.orange)
                    .accessibilityLabel(statusLabel(status))
            }
        }
        .frame(minHeight: 36)
        .contentShape(Rectangle())
    }

    private var symbol: String {
        if entry.isDir { return expanded ? "folder.fill" : "folder" }
        return "doc.text"
    }

    private func statusLetter(_ status: WorkingTreeStatus) -> String {
        switch status {
        case .modified: return "M"
        case .untracked: return "U"
        case .unknown: return "?"
        }
    }

    private func statusLabel(_ status: WorkingTreeStatus) -> Text {
        switch status {
        case .modified: return Text("Modified")
        case .untracked: return Text("Untracked")
        case .unknown: return Text("Changed")
        }
    }
}

/// One file, read-only, with line numbers and the transcript's own
/// highlighter.
///
/// Rows are virtualized because a source file is a long collection and a phone
/// scrolls it: building a `Text` per line up front would spend the whole frame
/// budget on lines nobody has reached. Highlighting runs once over the whole
/// file off the main thread and is then split per line, because a string or a
/// block comment that crosses lines only lexes correctly when the lexer sees
/// it whole.
struct FileReaderView: View {
    let surfaces: WorkspaceSurfaces
    let path: WorkspaceRelativePath
    let line: Int?

    /// The file split into rows, with the highlight spans for each if it was
    /// small enough to lex. Both are built once, off the main actor, and then
    /// only read — a row builder that re-split the file would spend the frame
    /// budget on lines nobody has scrolled to.
    private struct Prepared: Sendable {
        var lines: [Substring]
        var spans: [[HighlightedSpan]]?
    }

    @State private var prepared: Prepared?
    @State private var wrapLines = false

    /// Past this a file reads as a blob, and highlighting it would cost more
    /// than the reading is worth.
    private static let maxHighlightBytes = 512 * 1024

    private var content: String? {
        surfaces.openFile?.relativePath == path ? surfaces.openFile?.content : nil
    }

    private var error: String? {
        surfaces.openFile?.relativePath == path ? surfaces.openFile?.error : nil
    }

    /// Stands in for the content as a task id. Comparing whole files on every
    /// body evaluation is the cost this view exists to avoid, and a string's
    /// UTF-8 length is held by its own storage rather than counted.
    private struct ContentToken: Equatable {
        var path: WorkspaceRelativePath
        var bytes: Int?
    }

    private var contentToken: ContentToken {
        ContentToken(path: path, bytes: content?.utf8.count)
    }

    var body: some View {
        Group {
            if let error {
                ContentUnavailableView {
                    Label("Could not read this file", systemImage: "doc.questionmark")
                } description: {
                    Text(error)
                } actions: {
                    Button("Try again") { surfaces.openFile(path, focusLine: line) }
                }
            } else if let prepared {
                reader(prepared)
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle(path.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Toggle("Wrap lines", isOn: $wrapLines)
                        .keyboardShortcut("l", modifiers: [.command, .shift])
                    if let content {
                        Button {
                            UIPasteboard.general.string = content
                        } label: {
                            Label("Copy file", systemImage: "doc.on.doc")
                        }
                        .keyboardShortcut("c", modifiers: [.command, .shift])
                    }
                    Section {
                        Text(verbatim: path.rawValue)
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .accessibilityLabel("File options")
            }
        }
        .task(id: path) {
            if surfaces.openFile?.relativePath != path || surfaces.openFile?.content == nil {
                surfaces.openFile(path, focusLine: line)
            }
        }
        .task(id: contentToken) { await prepare() }
    }

    private func reader(_ prepared: Prepared) -> some View {
        ScrollViewReader { proxy in
            ScrollView([.vertical, wrapLines ? [] : .horizontal]) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    // Indices rather than `enumerated()`: the list is lazy, and
                    // materialising a pair per line would walk the whole file
                    // to draw a screenful of it.
                    ForEach(prepared.lines.indices, id: \.self) { index in
                        LineRow(
                            number: index + 1,
                            text: prepared.lines[index],
                            spans: prepared.spans?.indices.contains(index) == true
                                ? prepared.spans?[index] : nil,
                            wraps: wrapLines,
                            isFocused: line == index + 1
                        )
                        .id(index + 1)
                    }
                }
                .padding(.vertical, 8)
            }
            .onAppear {
                // A transcript link named a line; land on it rather than at
                // the top of a file the reader has to search.
                guard let line, prepared.lines.count >= line else { return }
                proxy.scrollTo(line, anchor: .center)
            }
        }
    }

    /// Splitting a large file and lexing it are both work a frame must not
    /// reach, so both happen off the main actor and land together as one
    /// value. Until they do, `prepared` is nil and the view shows progress.
    private func prepare() async {
        guard let content else {
            prepared = nil
            return
        }
        let language = path.rawValue.split(separator: ".").last.map(String.init)
        let lexes = content.utf8.count <= Self.maxHighlightBytes
        let built = await Task.detached(priority: .utility) { () -> Prepared in
            var lines = content.split(separator: "\n", omittingEmptySubsequences: false)
            if lines.last?.isEmpty == true { lines.removeLast() }
            let spans =
                lexes
                ? SyntaxHighlight.spansByLine(
                    SyntaxHighlight.spans(of: content, language: language))
                : nil
            return Prepared(lines: lines, spans: spans)
        }.value
        guard surfaces.openFile?.relativePath == path else { return }
        prepared = built
    }
}

private struct LineRow: View {
    let number: Int
    let text: Substring
    let spans: [HighlightedSpan]?
    let wraps: Bool
    let isFocused: Bool

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text(verbatim: "\(number)")
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.tertiary)
                .frame(minWidth: 34, alignment: .trailing)
                .accessibilityHidden(true)
            Text(attributed)
                .font(.system(.footnote, design: .monospaced))
                .textSelection(.enabled)
                .fixedSize(horizontal: !wraps, vertical: false)
            if wraps { Spacer(minLength: 0) }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 1)
        .background(isFocused ? Color.accentColor.opacity(0.15) : .clear)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Line \(number): \(text)")
    }

    private var attributed: AttributedString {
        guard let spans, !spans.isEmpty else { return AttributedString(String(text)) }
        var out = AttributedString()
        for span in spans {
            var piece = AttributedString(span.text)
            piece.foregroundColor = SyntaxPalette.color(for: span.token, scheme: colorScheme)
            out += piece
        }
        return out
    }
}
