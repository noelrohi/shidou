import ShidouProtocol
import ShidouSession
import SwiftUI

/// The review diff: a file list that pushes to one file's unified diff.
///
/// Side-by-side is deferred past v1 on both iPhone and iPad — two columns of
/// code do not fit a phone, and half a diff at readable type is worse than a
/// whole one in a single column.
struct ChangesView: View {
    let surfaces: WorkspaceSurfaces
    let session: AgentSession
    let store: SessionStore

    @State private var showingCommit = false

    var body: some View {
        List {
            if !surfaces.diffIsComplete {
                Section {
                    Label {
                        Text("The daemon could not include full context for this change. Some lines are missing.")
                            .font(.footnote)
                    } icon: {
                        Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                    }
                }
            }
            Section {
                ForEach(surfaces.diffFiles) { file in
                    NavigationLink(value: SurfaceRoute.change(index: file.index)) {
                        DiffFileRow(file: file)
                    }
                }
            } header: {
                if !surfaces.diffFiles.isEmpty {
                    Text(
                        "\(surfaces.diffFiles.count) file · +\(surfaces.diffAdditions) −\(surfaces.diffDeletions)"
                    )
                }
            }
        }
        .listStyle(.insetGrouped)
        .surfaceState(
            isEmpty: surfaces.diffFiles.isEmpty,
            isLoading: surfaces.isLoadingDiff,
            error: surfaces.diffError,
            hasLoaded: surfaces.hasLoadedDiff,
            retry: { surfaces.loadDiff(force: true) },
            failureTitle: "Could not read the diff",
            failureIcon: "plusminus.circle"
        ) {
            ContentUnavailableView(
                "No changes", systemImage: "checkmark.circle",
                description: Text("Nothing has changed in this range."))
        }
        .navigationTitle("Changes")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { surfaces.loadDiff(force: true) }
        .task(id: surfaces.workspaceRevision) { surfaces.loadDiff(force: true) }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Picker("Range", selection: sourceBinding) {
                        ForEach(DiffSourceChoice.allCases) { choice in
                            Text(choice.label).tag(choice)
                        }
                    }
                    Button {
                        showingCommit = true
                    } label: {
                        Label("Commit…", systemImage: "arrow.up.circle")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .accessibilityLabel("Diff options")
            }
        }
        .sheet(isPresented: $showingCommit) {
            CommitSheet(session: session, store: store, cwd: surfaces.cwd)
        }
    }

    private var sourceBinding: Binding<DiffSourceChoice> {
        Binding(
            get: { DiffSourceChoice(surfaces.diffSource) },
            set: { surfaces.selectDiffSource($0.source) }
        )
    }
}

/// The ranges a phone offers. The desktop also offers a specific past turn;
/// that needs a turn picker the sheet has no room for, and "Uncommitted" is
/// the range someone reviewing on a phone actually wants.
enum DiffSourceChoice: String, CaseIterable, Identifiable, Hashable {
    case uncommitted, unstaged, staged, committed, branch

    var id: String { rawValue }

    init(_ source: ReviewDiffSource) {
        switch source {
        case .unstaged: self = .unstaged
        case .staged: self = .staged
        case .committed: self = .committed
        case .branch: self = .branch
        case .uncommitted, .lastTurn: self = .uncommitted
        }
    }

    var source: ReviewDiffSource {
        switch self {
        case .uncommitted: return .uncommitted
        case .unstaged: return .unstaged
        case .staged: return .staged
        case .committed: return .committed
        case .branch: return .branch
        }
    }

    var label: LocalizedStringKey {
        switch self {
        case .uncommitted: return "Uncommitted"
        case .unstaged: return "Unstaged"
        case .staged: return "Staged"
        case .committed: return "Committed"
        case .branch: return "Branch"
        }
    }
}

private struct DiffFileRow: View {
    let file: UnifiedDiff.File

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.footnote)
                .foregroundStyle(tint)
                .frame(width: 18)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: file.name).lineLimit(1).truncationMode(.middle)
                if let previous = file.previousPath {
                    Text("was \(previous)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                } else if !file.directory.isEmpty {
                    Text(verbatim: file.directory)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
            }
            Spacer(minLength: 8)
            if file.change != .binary {
                Text(verbatim: "+\(file.additions) −\(file.deletions)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .frame(minHeight: 40)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
    }

    private var symbol: String {
        switch file.change {
        case .added: return "plus.square"
        case .deleted: return "minus.square"
        case .renamed: return "arrow.turn.up.right"
        case .binary: return "doc.badge.gearshape"
        case .modified: return "pencil"
        }
    }

    private var tint: Color {
        switch file.change {
        case .added: return .green
        case .deleted: return .red
        default: return .secondary
        }
    }

    /// One whole sentence per case rather than pieces joined with a space:
    /// a fragment like " %@" is not a string a translator can place.
    private var accessibilityLabel: Text {
        if file.change == .binary { return Text("Binary file \(file.path)") }
        let stat = "+\(file.additions) −\(file.deletions)"
        switch file.change {
        case .added: return Text("Added \(file.path), \(stat)")
        case .deleted: return Text("Deleted \(file.path), \(stat)")
        case .renamed: return Text("Renamed to \(file.path), \(stat)")
        case .modified, .binary: return Text("Modified \(file.path), \(stat)")
        }
    }
}

/// One file's unified diff. Lines are virtualized: a diff is a long
/// collection, and building a row per line up front is exactly the frame cost
/// the phone cannot afford on a large change.
struct DiffFileView: View {
    let surfaces: WorkspaceSurfaces
    let index: Int

    private var file: UnifiedDiff.File? {
        surfaces.diffFiles.first { $0.index == index }
    }

    var body: some View {
        Group {
            if let file {
                if file.change == .binary {
                    ContentUnavailableView(
                        "Binary file", systemImage: "doc.badge.gearshape",
                        description: Text("There is no text diff to show for \(file.name)."))
                } else {
                    diff(file)
                }
            } else {
                ContentUnavailableView(
                    "This file is no longer in the diff", systemImage: "questionmark.folder")
            }
        }
        .navigationTitle(file?.name ?? "Diff")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func diff(_ file: UnifiedDiff.File) -> some View {
        ScrollView([.vertical, .horizontal]) {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(file.hunks) { hunk in
                    HunkHeaderRow(hunk: hunk)
                    ForEach(hunk.lines) { line in
                        DiffLineRow(line: line)
                    }
                }
            }
            .padding(.vertical, 8)
        }
        .defaultScrollAnchor(.topLeading)
    }
}

private struct HunkHeaderRow: View {
    let hunk: UnifiedDiff.Hunk

    var body: some View {
        HStack(spacing: 8) {
            Text(verbatim: range)
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.secondary)
            if !hunk.context.isEmpty {
                Text(verbatim: hunk.context)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.06))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Hunk \(range)")
    }

    /// The `@@ … @@` part, without the trailing function context that gets its
    /// own label.
    private var range: String {
        guard let end = hunk.header.range(of: "@@", options: .backwards) else {
            return hunk.header
        }
        return String(hunk.header[..<end.upperBound])
    }
}

private struct DiffLineRow: View {
    let line: UnifiedDiff.Line

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text(verbatim: String(line.newNumber ?? line.oldNumber ?? 0))
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.tertiary)
                .frame(minWidth: 30, alignment: .trailing)
                .accessibilityHidden(true)
            // The marker is text, so an added line is not only a green one.
            Text(verbatim: marker)
                .font(.system(.footnote, design: .monospaced))
                .foregroundStyle(markerTint)
                .frame(width: 10, alignment: .leading)
                .accessibilityHidden(true)
            Text(verbatim: line.content.isEmpty ? " " : line.content)
                .font(.system(.footnote, design: .monospaced))
                .textSelection(.enabled)
                .fixedSize(horizontal: true, vertical: false)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 1)
        .background(background)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
    }

    private var marker: String {
        switch line.kind {
        case .addition: return "+"
        case .deletion: return "−"
        case .context: return " "
        }
    }

    private var markerTint: Color {
        switch line.kind {
        case .addition: return .green
        case .deletion: return .red
        case .context: return .secondary
        }
    }

    private var background: Color {
        let strength = colorScheme == .dark ? 0.22 : 0.12
        switch line.kind {
        case .addition: return Color.green.opacity(strength)
        case .deletion: return Color.red.opacity(strength)
        case .context: return .clear
        }
    }

    private var accessibilityLabel: Text {
        let number = line.newNumber ?? line.oldNumber ?? 0
        switch line.kind {
        case .addition: return Text("Added line \(number): \(line.content)")
        case .deletion: return Text("Removed line \(number): \(line.content)")
        case .context: return Text("Line \(number): \(line.content)")
        }
    }
}
