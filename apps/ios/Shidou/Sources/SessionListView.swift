import ShidouProtocol
import ShidouSession
import SwiftUI

/// Sessions, the root of the navigation spine. One section per recency
/// bucket; rows carry what the web sidebar carries, at mobile density.
struct SessionListView: View {
    @Binding var selection: UUID?

    @Environment(DaemonConnection.self) private var connection

    @State private var now = Date()
    @State private var renaming: AgentSession?
    @State private var renameText = ""
    @State private var deleting: AgentSession?
    @State private var actionError: String?

    private var store: SessionStore? { connection.sessions }

    var body: some View {
        list
            .listStyle(.insetGrouped)
            .overlay { emptyState }
            .refreshable { store?.refreshCatalog() }
            .task(id: tickKey) { await tick() }
            .alert("Rename task", isPresented: Binding(
                get: { renaming != nil },
                set: { if !$0 { renaming = nil } }
            )) {
                TextField("Title", text: $renameText)
                Button("Cancel", role: .cancel) { renaming = nil }
                Button("Rename") { commitRename() }
            }
            .confirmationDialog(
                "Delete this task?",
                isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                titleVisibility: .visible
            ) {
                Button("Delete", role: .destructive) { commitDelete() }
                Button("Cancel", role: .cancel) { deleting = nil }
            } message: {
                Text("Its transcript is removed from the daemon. This cannot be undone.")
            }
            .alert("Something went wrong", isPresented: Binding(
                get: { actionError != nil },
                set: { if !$0 { actionError = nil } }
            )) {
                Button("OK") { actionError = nil }
            } message: {
                Text(actionError ?? "")
            }
    }

    private var list: some View {
        List(selection: $selection) { rows }
            .listStyle(.insetGrouped)
    }

    @ViewBuilder
    private var rows: some View {
        ForEach(sections) { section in
            Section(section.group.title) {
                ForEach(section.items) { item in
                    row(item)
                }
            }
        }
    }

    // MARK: - Rows

    private func row(_ item: SessionListItem) -> some View {
        SessionRow(item: item, now: UInt64(now.timeIntervalSince1970))
            .tag(item.session.id)
            .swipeActions(edge: .trailing) { actions(for: item) }
            // A swipe is invisible to VoiceOver and unreachable from a keyboard,
            // so the same actions are also a context menu that focus can open.
            .contextMenu { actions(for: item) }
    }

    @ViewBuilder
    private func actions(for item: SessionListItem) -> some View {
        Button(role: .destructive) {
            deleting = item.session
        } label: {
            Label("Delete", systemImage: "trash")
        }
        Button {
            renaming = item.session
            renameText = displayTitle(item.session)
        } label: {
            Label("Rename", systemImage: "pencil")
        }
        .tint(.indigo)
    }

    @ViewBuilder
    private var emptyState: some View {
        if let store, store.hasLoadedCatalog, sections.isEmpty {
            ContentUnavailableView {
                Label("No tasks yet", systemImage: "tray")
            } description: {
                Text("Start one with ＋, or from Shidou on your Mac.")
            }
        } else if let error = store?.catalogError {
            ContentUnavailableView {
                Label("Could not load your tasks", systemImage: "exclamationmark.triangle")
            } description: {
                Text(error)
            } actions: {
                Button("Try again") { store?.refreshCatalog() }
            }
        } else if store?.hasLoadedCatalog != true {
            ProgressView()
        }
    }

    // MARK: - Data

    private var sections: [SessionListSection] {
        guard let store else { return [] }
        return SessionListPresentation.sections(
            sessions: store.sessions, projects: store.projects, now: now
        )
    }

    /// The list re-times itself only when what it would say changes: seconds
    /// while a turn runs, and otherwise the next minute, hour, or midnight.
    private var tickKey: Int {
        store?.sessions.reduce(into: 0) { $0 ^= $1.status.hashValue } ?? 0
    }

    private func tick() async {
        guard let store else { return }
        while !Task.isCancelled {
            let delay = SessionListPresentation.nextRefreshDelay(store.sessions, now: now)
            try? await Task.sleep(for: .seconds(delay))
            if Task.isCancelled { return }
            now = Date()
        }
    }

    private func commitRename() {
        guard let session = renaming, let store else { return }
        let title = renameText
        renaming = nil
        Task {
            do { try await store.rename(session.id, to: title) } catch {
                actionError = error.localizedDescription
            }
        }
    }

    private func commitDelete() {
        guard let session = deleting, let store else { return }
        deleting = nil
        Task {
            do {
                if selection == session.id { selection = nil }
                try await store.delete(session.id)
            } catch {
                actionError = error.localizedDescription
            }
        }
    }
}

struct SessionRow: View {
    let item: SessionListItem
    let now: UInt64

    /// The status column keeps the titles aligned, and scales with the text so
    /// a larger type size does not crop the glyph into it.
    @ScaledMetric(relativeTo: .footnote) private var glyphColumn: CGFloat = 18

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            statusGlyph
            VStack(alignment: .leading, spacing: 3) {
                Text(displayTitle(item.session))
                    .font(.body)
                    .lineLimit(2)
                HStack(spacing: 6) {
                    Text(item.projectName)
                    if let branch = item.branch {
                        Text(verbatim: "·").foregroundStyle(.quaternary).accessibilityHidden(true)
                        Label(branch, systemImage: "arrow.triangle.branch")
                            .labelStyle(.titleAndIcon)
                            .lineLimit(1)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                if !statusLabel.isEmpty {
                    Text(statusLabel)
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(item.isWaiting ? AnyShapeStyle(Color.orange) : AnyShapeStyle(.tertiary))
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
    }

    /// A Waiting Session is marked with a glyph and a sentence, not with a
    /// colour: the whole point of the mark is that it must not be missable.
    private var statusGlyph: some View {
        Image(systemName: glyphName)
            .font(.footnote)
            .foregroundStyle(glyphColor)
            .frame(minWidth: glyphColumn, alignment: .leading)
            .accessibilityHidden(true)
    }

    private var glyphName: String {
        switch item.session.status {
        case .waiting: return "hand.raised.fill"
        case .failed: return "exclamationmark.triangle.fill"
        case .working, .connecting: return "circle.dotted"
        case .idle, .unknown: return "checkmark.circle"
        }
    }

    private var glyphColor: Color {
        switch item.session.status {
        case .waiting: return .orange
        case .failed: return .red
        case .working, .connecting: return .accentColor
        case .idle, .unknown: return .secondary
        }
    }

    private var statusLabel: String {
        switch SessionListPresentation.rowStatus(item.session, now: now) {
        case .waiting:
            return String(localized: "Waiting for you")
        case .failed:
            return String(localized: "Stopped")
        case .working(let elapsed):
            return String(localized: "Working for \(elapsed.durationShortLabel)")
        case .replied(let ago):
            return ago.agoLabel
        case .none:
            return ""
        }
    }

    private var accessibilityLabel: String {
        var parts = [displayTitle(item.session), item.projectName]
        if let branch = item.branch { parts.append(String(localized: "on branch \(branch)")) }
        if !statusLabel.isEmpty { parts.append(statusLabel) }
        return parts.joined(separator: ", ")
    }
}

extension SessionDateGroup {
    var title: String {
        switch self {
        case .today: return String(localized: "Today")
        case .yesterday: return String(localized: "Yesterday")
        case .week: return String(localized: "This Week")
        case .month: return String(localized: "This Month")
        case .year: return String(localized: "This Year")
        case .more: return String(localized: "Older")
        }
    }
}

extension Int {
    /// "just now", "4m", "3h", "2d" — the sidebar's own scale.
    var agoLabel: String {
        if self < 60 { return String(localized: "just now") }
        if self < 3_600 { return "\(self / 60)m" }
        if self < 86_400 { return "\(self / 3_600)h" }
        return "\(self / 86_400)d"
    }
}
