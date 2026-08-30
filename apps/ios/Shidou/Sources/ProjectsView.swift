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
    private var projects: [(project: Project, taskCount: Int, lastTouched: UInt64)] {
        guard let store else { return [] }
        var byProject: [UUID: (count: Int, latest: UInt64)] = [:]
        for session in store.sessions where SessionListPresentation.hasStarted(session) {
            let stamp = SessionListPresentation.timestamp(session)
            let entry = byProject[session.projectId] ?? (0, 0)
            byProject[session.projectId] = (entry.count + 1, max(entry.latest, stamp))
        }
        return store.projects
            .map { project in
                let entry = byProject[project.id] ?? (0, project.createdAt)
                return (project, entry.count, entry.latest)
            }
            .sorted { $0.lastTouched > $1.lastTouched }
    }

    var body: some View {
        List(projects, id: \.project.id) { entry in
            NavigationLink {
                ProjectTasksView(project: entry.project, selection: $selection)
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "folder")
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .frame(width: 24)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.project.name)
                            .font(.body)
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        Text(entry.project.path.abbreviatingHome)
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
                Text("\(entry.project.name), \(entry.taskCount) tasks")
            )
        }
        .listStyle(.plain)
        .navigationTitle("Projects")
        .navigationBarTitleDisplayMode(.large)
        .overlay {
            if let store, store.hasLoadedCatalog, projects.isEmpty {
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

/// One project's tasks, newest first, in the rows the list uses.
private struct ProjectTasksView: View {
    let project: Project
    @Binding var selection: UUID?

    @Environment(DaemonConnection.self) private var connection
    @State private var now = Date()

    private var store: SessionStore? { connection.sessions }

    private var items: [SessionListItem] {
        guard let store else { return [] }
        return SessionListPresentation.groups(
            sessions: store.sessions.filter { $0.projectId == project.id },
            projects: store.projects,
            grouping: .updated,
            ordering: .newest
        )
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
        .navigationTitle(project.name)
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
