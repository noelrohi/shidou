import ShidouProtocol
import ShidouSession
import SwiftUI

/// The sidebar's Projects destination: every project the daemon knows, and
/// the tasks filed under each.
///
/// The task list already files by project when asked, but a flat list of
/// projects is a different question — "what am I working on" rather than
/// "what did I do last" — and it earns its own screen the way Claude's
/// sidebar gives Projects a row of its own. Picking a task here selects it
/// exactly as the list would.
struct ProjectsView: View {
    @Binding var selection: UUID?

    @Environment(DaemonConnection.self) private var connection

    private var store: SessionStore? { connection.sessions }

    /// Projects with the most recently touched first, so the one you are in
    /// the middle of is at the top rather than wherever it was created.
    ///
    /// The daemon files every folderless task under its own scratch project,
    /// so left alone the list fills with "No project" rows between the real
    /// ones. Those fold into a single row that carries all of their tasks.
    private var entries: [ProjectsEntry] {
        guard let store else { return [] }
        var byProject: [UUID: (count: Int, latest: UInt64)] = [:]
        for session in store.sessions where SessionListPresentation.hasStarted(session) {
            let stamp = SessionListPresentation.timestamp(session)
            let entry = byProject[session.projectId] ?? (0, 0)
            byProject[session.projectId] = (entry.count + 1, max(entry.latest, stamp))
        }
        var entries: [ProjectsEntry] = []
        var scratch: [Project] = []
        var scratchCount = 0
        var scratchLatest: UInt64 = 0
        for project in store.projects {
            let stats = byProject[project.id] ?? (0, project.createdAt)
            if project.isProjectless {
                scratch.append(project)
                scratchCount += stats.count
                scratchLatest = max(scratchLatest, stats.latest)
                continue
            }
            entries.append(
                ProjectsEntry(
                    id: project.id, title: project.name, subtitle: project.path.abbreviatingHome,
                    icon: "folder", projectIds: [project.id], taskCount: stats.count,
                    lastTouched: stats.latest))
        }
        if !scratch.isEmpty {
            entries.append(
                ProjectsEntry(
                    id: ProjectsEntry.projectlessId, title: String(localized: "No project"),
                    subtitle: Self.commonParent(of: scratch.map(\.path)).abbreviatingHome,
                    icon: "tray", projectIds: Set(scratch.map(\.id)), taskCount: scratchCount,
                    lastTouched: scratchLatest))
        }
        return entries.sorted { $0.lastTouched > $1.lastTouched }
    }

    /// The deepest directory every path sits under, so the scratch row reads
    /// `~/.shidou/projects` rather than one arbitrary workspace's path.
    static func commonParent(of paths: [String]) -> String {
        guard var common = paths.first.map({ $0.split(separator: "/", omittingEmptySubsequences: false) })
        else { return "" }
        for path in paths.dropFirst() {
            let parts = path.split(separator: "/", omittingEmptySubsequences: false)
            let shared = zip(common, parts).prefix { $0 == $1 }.count
            common = Array(common.prefix(shared))
        }
        let joined = common.joined(separator: "/")
        return joined.isEmpty ? "/" : joined
    }

    var body: some View {
        List(entries) { entry in
            NavigationLink {
                ProjectTasksView(
                    title: entry.title, projectIds: entry.projectIds, selection: $selection)
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: entry.icon)
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .frame(width: 24)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.title)
                            .font(.body)
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        Text(entry.subtitle)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.head)
                    }
                    Spacer(minLength: 8)
                    Text(entry.taskCount, format: .number)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                .padding(.vertical, 4)
            }
            .accessibilityLabel(
                Text("\(entry.title), \(entry.taskCount) tasks")
            )
        }
        .listStyle(.plain)
        .navigationTitle("Projects")
        .navigationBarTitleDisplayMode(.large)
        .overlay {
            if let store, store.hasLoadedCatalog, entries.isEmpty {
                ContentUnavailableView(
                    "No projects yet",
                    systemImage: "folder",
                    description: Text("Start a task in a folder on your Mac and it shows up here.")
                )
            }
        }
        .refreshable { store?.refreshCatalog() }
    }
}

/// One row of the projects list: a project, or every scratch project folded
/// into one.
private struct ProjectsEntry: Identifiable {
    static let projectlessId = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!

    let id: UUID
    let title: String
    let subtitle: String
    let icon: String
    let projectIds: Set<UUID>
    let taskCount: Int
    let lastTouched: UInt64
}

/// `ProjectsView` as its own screen: a stack with a close button, covering the
/// drawer on the phone. Picking a task anywhere in the stack closes it.
struct ProjectsScreen: View {
    @Binding var selection: UUID?

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ProjectsView(selection: $selection)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button { dismiss() } label: {
                            Image(systemName: "xmark")
                        }
                        .accessibilityLabel("Close projects")
                        .keyboardShortcut(.cancelAction)
                    }
                }
        }
        .onChange(of: selection) { _, newValue in
            if newValue != nil { dismiss() }
        }
    }
}

/// One project's tasks, newest first, in the rows the list uses. The scratch
/// row passes every projectless project, so its tasks land here together.
private struct ProjectTasksView: View {
    let title: String
    let projectIds: Set<UUID>
    @Binding var selection: UUID?

    @Environment(DaemonConnection.self) private var connection
    @State private var now = Date()

    private var store: SessionStore? { connection.sessions }

    private var items: [SessionListItem] {
        guard let store else { return [] }
        return SessionListPresentation.groups(
            sessions: store.sessions.filter { projectIds.contains($0.projectId) },
            projects: store.projects,
            grouping: .updated,
            ordering: .newest
        )
        // An Archived Task has left the project's history for the Task Shelf,
        // which the task list draws; this screen is the history.
        .filter { !$0.isShelf }
        .flatMap(\.items)
    }

    var body: some View {
        List(items) { item in
            Button {
                selection = item.session.id
            } label: {
                SessionRow(item: item, now: UInt64(now.timeIntervalSince1970))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            .buttonStyle(.plain)
            .listRowInsets(EdgeInsets(top: 1, leading: 12, bottom: 1, trailing: 12))
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
        }
        .listStyle(.plain)
        .environment(\.defaultMinListRowHeight, 1)
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .overlay {
            if items.isEmpty {
                ContentUnavailableView(
                    "No tasks in this project",
                    systemImage: "text.bubble",
                    description: Text("Start one with New task.")
                )
            }
        }
        .task(id: tickKey) { await tick() }
    }

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
}

private extension String {
    /// `/Users/me/code/app` → `~/code/app`, as the Mac's own sidebar shows it.
    var abbreviatingHome: String {
        let marker = "/Users/"
        guard hasPrefix(marker) else { return self }
        let rest = dropFirst(marker.count)
        guard let slash = rest.firstIndex(of: "/") else { return "~" }
        return "~" + rest[slash...]
    }
}
