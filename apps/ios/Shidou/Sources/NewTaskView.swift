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
    /// The task that was open when New Task was chosen. Its project and
    /// composer setup seed this draft without coupling the new transcript to
    /// the old task's history or worktree.
    let sourceSessionId: UUID?
    /// Passed through to the transcript, whose toolbar hosts the drawer
    /// button on iPhone.
    var opensDrawer: (() -> Void)?

    init(sourceSessionId: UUID? = nil, opensDrawer: (() -> Void)? = nil) {
        self.sourceSessionId = sourceSessionId
        self.opensDrawer = opensDrawer
    }

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
        guard draft == nil, let store else { return }
        let source = sourceSession(in: store)
        guard let project = preferredProject(in: store, source: source) else { return }

        let preferences = ComposerPreferenceStore().preferences(for: connection.preferenceKey)
        // Unknown providers can survive in an older catalog, but cannot seed a
        // runnable task in this build.
        let template = source?.provider == .unknown ? nil : source
        var session = newSession(
            projectId: project.id,
            provider: template?.provider ?? preferences.lastProvider,
            isolated: project.workspaceDefault == .newWorktree
        )
        if let template {
            session.model = template.model
            session.reasoningEffort = template.reasoningEffort
            session.serviceTier = template.serviceTier
            session.contextWindow = template.contextWindow
            session.runtimeMode = template.runtimeMode
            session.interactionMode = template.interactionMode
            session.agentPreset = template.agentPreset
        } else {
            session.model = preferences.lastModel
            session.reasoningEffort = preferences.lastReasoningEffort
            session.serviceTier = preferences.lastServiceTier
            session.contextWindow = preferences.lastContextWindow
        }
        draft = session
        store.adopt(session)
    }

    private func sourceSession(in store: SessionStore) -> AgentSession? {
        guard let sourceSessionId else { return nil }
        return store.open[sourceSessionId]?.currentProjection
            ?? store.sessions.first { $0.id == sourceSessionId }
    }

    /// Prefer the task the user came from. A fresh task follows the project's
    /// workspace default; it never reuses the source task's worktree.
    private func preferredProject(in store: SessionStore, source: AgentSession?) -> Project? {
        let sourceProject = source.flatMap { session in
            store.projects.first { $0.id == session.projectId }
        }
        if let sourceProject { return sourceProject }

        let recent = store.sessions.first.flatMap { session in
            store.projects.first { $0.id == session.projectId }
        }
        if let recent, !recent.isProjectless { return recent }
        return store.projects.first { !$0.isProjectless } ?? store.projects.first
    }
}
