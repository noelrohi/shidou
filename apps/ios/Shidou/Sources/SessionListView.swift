import ShidouProtocol
import ShidouSession
import SwiftUI

/// The task list, shared by the iPhone drawer and the iPad sidebar.
///
/// It carries what the web sidebar carries, at mobile density: a search row
/// that routes to the search screen, collapsible sections that file tasks
/// either by recency or by project, an options menu on the first header that
/// chooses between the two, and rows that say what the task is, where it
/// lives, and what it is doing.
struct SessionListView: View {
    @Binding var selection: UUID?

    @Environment(DaemonConnection.self) private var connection

    /// Same defaults keys the web client uses, because the two clients are the
    /// same product and a person who files by project on one means it on both.
    @AppStorage("shidou.sidebarGrouping") private var groupingChoice = SessionListGrouping.updated.rawValue
    @AppStorage("shidou.sidebarOrdering") private var orderingChoice = SessionListOrdering.newest.rawValue

    @State private var showingSearch = false
    @State private var collapsed: Set<String> = []
    /// Per project section: how many tasks older than the recent window the
    /// user has asked to see.
    @State private var revealed: [String: Int] = [:]
    @State private var now = Date()
    @State private var renaming: AgentSession?
    @State private var renameText = ""
    @State private var deleting: AgentSession?
    @State private var actionError: String?

    private var store: SessionStore? { connection.sessions }

    private var grouping: SessionListGrouping {
        SessionListGrouping(rawValue: groupingChoice) ?? .updated
    }

    private var ordering: SessionListOrdering {
        SessionListOrdering(rawValue: orderingChoice) ?? .newest
    }

    var body: some View {
        VStack(spacing: 0) {
            searchRow
            list
                .overlay { emptyState }
        }
        .navigationDestination(isPresented: $showingSearch) {
            SearchView(selection: $selection)
        }
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

    // MARK: - Search

    /// A field's face on a button's body: the tap routes to `SearchView`,
    /// where focus, keyboard, and results get a whole screen. Filtering this
    /// list in place made every keystroke shrink it and left no room to say
    /// what a query missed.
    private var searchRow: some View {
        Button {
            showingSearch = true
        } label: {
            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Text("Search tasks")
                    .font(.subheadline)
                    .foregroundStyle(.tertiary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                .quaternary.opacity(0.5),
                in: RoundedRectangle(cornerRadius: 10, style: .continuous)
            )
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("Opens search")
    }

    private var list: some View {
        List {
            ForEach(groups) { group in
                Section {
                    if !collapsed.contains(group.key) {
                        ForEach(group.items) { item in
                            row(item)
                        }
                        if group.hasMore {
                            showMore(group)
                        }
                    }
                } header: {
                    GroupHeader(
                        group: group,
                        collapsed: collapsed.contains(group.key),
                        showsOptions: group.key == groups.first?.key,
                        grouping: grouping,
                        ordering: ordering,
                        toggle: { toggle(group.key) },
                        chooseGrouping: { groupingChoice = $0.rawValue },
                        chooseOrdering: { orderingChoice = $0.rawValue }
                    )
                }
            }
            // Keeps the last row clear of the floating footer bar.
            Color.clear
                .frame(height: 64)
                .listRowInsets(EdgeInsets())
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
                .accessibilityHidden(true)
        }
        .listStyle(.plain)
        .environment(\.defaultMinListRowHeight, 1)
    }

    // MARK: - Rows

    private func row(_ item: SessionListItem) -> some View {
        let selected = selection == item.session.id
        return Button {
            selection = item.session.id
        } label: {
            SessionRow(
                item: item,
                now: UInt64(now.timeIntervalSince1970)
            )
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                selected ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear),
                in: RoundedRectangle(cornerRadius: 10, style: .continuous)
            )
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .listRowInsets(EdgeInsets(top: 1, leading: 12, bottom: 1, trailing: 12))
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
        .swipeActions(edge: .trailing) { actions(for: item) }
        // A swipe is invisible to VoiceOver and unreachable from a keyboard,
        // so the same actions are also a context menu that focus can open.
        .contextMenu { actions(for: item) }
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }

    private func showMore(_ group: SessionListGroup) -> some View {
        Button {
            revealed[group.key] = (revealed[group.key] ?? 0)
                + SessionListPresentation.projectRevealBatch
        } label: {
            Text("Show more")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowInsets(EdgeInsets(top: 1, leading: 24, bottom: 4, trailing: 12))
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
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
        if let store, store.hasLoadedCatalog, isEmpty {
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

    private var groups: [SessionListGroup] {
        guard let store else { return [] }
        return SessionListPresentation.groups(
            sessions: store.sessions,
            projects: store.projects,
            grouping: grouping,
            ordering: ordering,
            revealed: revealed,
            now: now,
            unknownProjectName: String(localized: "Unknown project"),
            projectlessName: String(localized: "No project")
        )
    }

    private var isEmpty: Bool { groups.allSatisfy { $0.items.isEmpty } }

    private func toggle(_ key: String) {
        withAnimation(.snappy(duration: 0.2)) {
            if collapsed.contains(key) {
                collapsed.remove(key)
            } else {
                collapsed.insert(key)
            }
        }
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

/// One collapsible section header — the web sidebar's `GroupRow`.
///
/// The first header also carries the options menu, so choosing how tasks are
/// filed costs no chrome of its own. Arrow keys collapse and expand, because a
/// disclosure that only answers to a tap is not a disclosure on a keyboard.
private struct GroupHeader: View {
    let group: SessionListGroup
    let collapsed: Bool
    let showsOptions: Bool
    let grouping: SessionListGrouping
    let ordering: SessionListOrdering
    let toggle: () -> Void
    let chooseGrouping: (SessionListGrouping) -> Void
    let chooseOrdering: (SessionListOrdering) -> Void

    var body: some View {
        HStack(spacing: 4) {
            Button(action: toggle) {
                HStack(spacing: 5) {
                    if group.isFolder {
                        Image(systemName: "folder")
                            .font(.caption2)
                            .accessibilityHidden(true)
                    }
                    Text(title)
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .bold))
                        .rotationEffect(.degrees(collapsed ? -90 : 0))
                        .foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                    Spacer(minLength: 0)
                }
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(title)
            .accessibilityValue(collapsed ? Text("Collapsed") : Text("Expanded"))
            .accessibilityHint("Shows or hides this section")
            .onKeyPress(.leftArrow) {
                guard !collapsed else { return .ignored }
                toggle()
                return .handled
            }
            .onKeyPress(.rightArrow) {
                guard collapsed else { return .ignored }
                toggle()
                return .handled
            }
            if showsOptions { options }
        }
        .textCase(nil)
        .padding(.horizontal, 12)
        .listRowInsets(EdgeInsets(top: 6, leading: 0, bottom: 2, trailing: 0))
    }

    private var title: String {
        if case .date(let bucket) = group.kind { return bucket.title }
        return group.folderName ?? ""
    }

    private var options: some View {
        Menu {
            Picker("Group by", selection: Binding(get: { grouping }, set: chooseGrouping)) {
                Text("Project").tag(SessionListGrouping.project)
                Text("Last updated").tag(SessionListGrouping.updated)
            }
            Picker("Order", selection: Binding(get: { ordering }, set: chooseOrdering)) {
                Text("Newest first").tag(SessionListOrdering.newest)
                Text("Oldest first").tag(SessionListOrdering.oldest)
            }
        } label: {
            Image(systemName: "line.3.horizontal.decrease")
                .font(.caption)
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        // A menu tints its label with the accent colour, which would make the
        // quietest control in the header the loudest thing in it.
        .foregroundStyle(.secondary)
        .accessibilityLabel("List options")
    }
}

/// One task in one compact line: agent and state, title, then right-aligned time.
struct SessionRow: View {
    let item: SessionListItem
    let now: UInt64

    var body: some View {
        HStack(spacing: 7) {
            providerImage
                .frame(width: 11, height: 11)
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)

            if showsStatusDot {
                Circle()
                    .fill(statusColor)
                    .frame(width: 6, height: 6)
                    .accessibilityHidden(true)
            }

            Text(displayTitle(item.session))
                .font(.subheadline)
                .foregroundStyle(.primary)
                .lineLimit(1)
                .layoutPriority(1)

            Spacer(minLength: 0)

            if !timeLabel.isEmpty {
                Text(timeLabel)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
    }

    @ViewBuilder
    private var providerImage: some View {
        if let assetName = item.session.provider.assetName {
            Image(assetName)
                .resizable()
                .renderingMode(.template)
                .scaledToFit()
        } else {
            Image(systemName: "terminal")
                .resizable()
                .scaledToFit()
        }
    }

    private var showsStatusDot: Bool {
        switch item.session.status {
        case .idle, .unknown: false
        case .connecting, .working, .waiting, .failed: true
        }
    }

    private var statusColor: Color {
        switch item.session.status {
        case .connecting, .working: .accentColor
        case .waiting: .orange
        case .failed: .red
        case .idle, .unknown: .secondary.opacity(0.45)
        }
    }

    private var timeLabel: String {
        switch SessionListPresentation.rowStatus(item.session, now: now) {
        case .working(let elapsed): elapsed.durationShortLabel
        case .waiting, .failed, .replied:
            item.session.lastReplyAt.map { Int(now > $0 ? now - $0 : 0).agoLabel } ?? ""
        case .none: ""
        }
    }

    private var statusDescription: String {
        switch item.session.status {
        case .connecting: String(localized: "Connecting")
        case .working: String(localized: "Working")
        case .waiting: String(localized: "Waiting for you")
        case .failed: String(localized: "Stopped")
        case .idle: String(localized: "Idle")
        case .unknown: String(localized: "Unknown status")
        }
    }

    private var accessibilityLabel: String {
        var parts = [
            displayTitle(item.session),
            item.projectName,
            item.session.provider.displayName,
            statusDescription,
        ]
        if let branch = item.branch { parts.append(String(localized: "on branch \(branch)")) }
        if !timeLabel.isEmpty { parts.append(timeLabel) }
        return parts.joined(separator: ", ")
    }
}

private extension ProviderKind {
    var assetName: String? {
        switch self {
        case .amp: "ProviderAmp"
        case .claude: "ProviderClaude"
        case .codex: "ProviderCodex"
        case .cursor: "ProviderCursor"
        case .deepSeek: "ProviderDeepSeek"
        case .fx: "ProviderFx"
        case .openCode: "ProviderOpenCode"
        case .grok: "ProviderGrok"
        case .kimi: "ProviderKimi"
        case .ohMyPi: "ProviderOhMyPi"
        case .pi: "ProviderPi"
        case .unknown: nil
        }
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
