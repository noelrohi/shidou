import ShidouProtocol
import ShidouSession
import SwiftUI

/// What ＋ opens: a task that does not exist yet.
///
/// It is a local draft until its first prompt — no row on the daemon, nothing
/// to clean up if the user backs out. What it does carry is the last thing
/// they started a task with, because reconfiguring the same model on every new
/// task is the tax a phone can least afford.
struct NewTaskView: View {
    /// Passed through to the transcript, whose toolbar hosts the drawer
    /// button on iPhone.
    var opensDrawer: (() -> Void)?

    @Environment(DaemonConnection.self) private var connection

    @State private var draft: AgentSession?
    @State private var addingProject = false

    private var store: SessionStore? { connection.sessions }

    var body: some View {
        Group {
            if let draft {
                TranscriptView(draft: draft, opensDrawer: opensDrawer)
            } else if let store, store.hasLoadedCatalog, store.projects.isEmpty {
                ContentUnavailableView {
                    Label("No projects yet", systemImage: "folder.badge.plus")
                } description: {
                    Text("Add a folder from your daemon's computer to start a task in it.")
                } actions: {
                    Button("Browse…") { addingProject = true }
                        .buttonStyle(.borderedProminent)
                }
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: store?.projects.count) { makeDraft() }
        // A New Task the user walked away from costs the daemon nothing, and
        // should cost this phone nothing either.
        .onDisappear {
            guard let draft, let store, store.open[draft.id]?.session.hasStarted != true else {
                return
            }
            store.close(draft.id)
        }
        .sheet(isPresented: $addingProject) {
            if let store {
                DirectoryBrowserView(mode: .project, store: store) { path in
                    (try? await store.addProject(path: path)) != nil
                }
            }
        }
    }

    private func makeDraft() {
        guard draft == nil, let store, let project = preferredProject(in: store) else { return }
        let preferences = ComposerPreferenceStore().preferences(for: connection.preferenceKey)
        var session = newSession(
            projectId: project.id,
            provider: preferences.lastProvider,
            isolated: project.workspaceDefault == .newWorktree
        )
        session.model = preferences.lastModel
        session.reasoningEffort = preferences.lastReasoningEffort
        session.serviceTier = preferences.lastServiceTier
        session.contextWindow = preferences.lastContextWindow
        draft = session
        store.adopt(session)
    }

    /// The project the last task ran in, so ＋ opens where work was left. The
    /// scratch workspace is never the default — it is something you ask for.
    private func preferredProject(in store: SessionStore) -> Project? {
        let recent = store.sessions.first.flatMap { session in
            store.projects.first { $0.id == session.projectId }
        }
        if let recent, !recent.isProjectless { return recent }
        return store.projects.first { !$0.isProjectless } ?? store.projects.first
    }
}
