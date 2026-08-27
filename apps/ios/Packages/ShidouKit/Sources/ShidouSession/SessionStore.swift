import Foundation
import Observation
import ShidouClient
import ShidouProtocol

/// The phone's whole client-side model of a daemon: its projects, its session
/// list, the projection of every session the user has open, and the drafts
/// typed against them.
///
/// It exists apart from the views because it is not view state. Reconnects,
/// replay cursors, catalog invalidation and command correlation are the app's
/// relationship with the daemon, and they have to survive a screen being
/// dismissed. Keeping it in `ShidouKit` rather than the app target is what
/// lets it be driven headlessly against a real `shidou-demo` — the store's
/// hardest behaviours are all reconnect behaviours, and none of them are
/// reachable through a view.
@MainActor
@Observable
public final class SessionStore {
    // MARK: Catalog

    public private(set) var projects: [Project] = []
    /// List projections: titles, status, recency. Transcripts arrive per
    /// session through `open(_:)`.
    public private(set) var sessions: [AgentSession] = []
    public private(set) var defaultCwd = ""
    public private(set) var isLoadingCatalog = false
    /// The last catalog load that failed, for the list's empty state. Cleared
    /// by the next success.
    public private(set) var catalogError: String?
    /// A catalog has landed at least once this connection, so an empty list
    /// means "no tasks" rather than "not loaded".
    public private(set) var hasLoadedCatalog = false

    // MARK: Open sessions

    /// Sessions with a live projection. A phone holds few of these on purpose:
    /// one transcript is what fits on screen, and the rest of the list is a
    /// catalog row until it is opened.
    public private(set) var open: [UUID: SessionRuntimeModel] = [:]
    /// Sessions whose replay came up short. Set the instant the daemon says so
    /// and cleared when the refetch lands; while set, events for that session
    /// are buffered rather than applied.
    public private(set) var refetching: Set<UUID> = []
    /// The most recent gap the daemon reported. Worth keeping rather than
    /// merely acting on: it is the one thing that explains why a transcript
    /// jumped, and the only evidence a client has that the phone was away
    /// longer than the daemon could remember.
    public private(set) var lastReplayGap: ReplayGap?

    /// Composer text typed but not sent, keyed by session. The composer itself
    /// arrives in the next slice; the model is owned here from the start so
    /// switching sessions never loses what was typed.
    public private(set) var drafts: [UUID: String] = [:]

    /// Git state per workspace directory, for the transcript header's
    /// branch and diff-stat subtitle. Refreshed in the background and read
    /// from the store on every frame — a miss means "not known yet".
    public private(set) var workspaces: [String: CommitSnapshot] = [:]

    // MARK: Wiring

    private let supervisor: ConnectionSupervisor
    private var pump: Task<Void, Never>?
    private var catalogTask: Task<Void, Never>?
    /// Events that arrived for a session while its refetch was in flight.
    private var buffered: [UUID: [SequencedEvent]] = [:]
    /// Rejects a catalog load that a newer one has already superseded.
    private var catalogGeneration = 0
    private var workspaceProbes: Set<String> = []

    public init(supervisor: ConnectionSupervisor) {
        self.supervisor = supervisor
    }

    /// Begin following the supervisor. Safe to call more than once.
    public func start() {
        guard pump == nil else { return }
        pump = Task { [weak self] in
            guard let supervisor = self?.supervisor else { return }
            for await event in await supervisor.events() {
                guard let self else { return }
                self.handle(event)
            }
        }
    }

    public func stop() {
        pump?.cancel()
        pump = nil
        catalogTask?.cancel()
        catalogTask = nil
        catalogGeneration &+= 1
        open.removeAll()
        refetching.removeAll()
        buffered.removeAll()
        workspaces.removeAll()
        workspaceProbes.removeAll()
        hasLoadedCatalog = false
        lastReplayGap = nil
    }

    // MARK: - Supervised events

    private func handle(_ event: SupervisedEvent) {
        switch event {
        case .phase(.connected):
            refreshCatalog()
        case .reconnected:
            // Replayed events follow on this same stream, so the projections
            // catch up on their own. What cannot: the catalog, whose other
            // clients may have renamed or removed a task while we were away.
            refreshCatalog()
            reattachOpenSessions()
        case .taskStateChanged:
            refreshCatalog()
        case .replayGap(let gap):
            lastReplayGap = gap
            beginRefetch(gap.sessionId)
        case .event(let event):
            apply(event)
        case .phase, .selectedCandidate:
            break
        }
    }

    private func apply(_ event: SequencedEvent) {
        // A session mid-refetch is holding a projection with a hole in it.
        // Buffering rather than applying is what stops the tail from landing
        // on top of that hole and looking like a complete transcript.
        if refetching.contains(event.sessionId) {
            buffered[event.sessionId, default: []].append(event)
            return
        }
        guard let model = open[event.sessionId] else { return }
        let result = model.apply(event)
        guard let result else { return }
        if result.settled || result.removeRuntime {
            persist(model.currentProjection)
            refreshWorkspace(for: model.currentProjection, force: true)
        }
    }

    // MARK: - Catalog

    public func refreshCatalog() {
        catalogGeneration &+= 1
        let generation = catalogGeneration
        catalogTask?.cancel()
        isLoadingCatalog = true
        catalogTask = Task { [weak self] in
            guard let self else { return }
            do {
                let payload = try await self.request(.loadTaskState)
                guard case .taskState(let projects, let sessions, let defaultCwd, _) = payload else {
                    throw ShidouSessionError.unexpectedResponse(expected: "taskState")
                }
                guard self.catalogGeneration == generation else { return }
                self.projects = projects
                self.sessions = sessions.sorted {
                    SessionListPresentation.timestamp($0) > SessionListPresentation.timestamp($1)
                }
                self.defaultCwd = defaultCwd
                self.catalogError = nil
                self.hasLoadedCatalog = true
                self.isLoadingCatalog = false
            } catch is CancellationError {
                return
            } catch {
                guard self.catalogGeneration == generation else { return }
                self.isLoadingCatalog = false
                self.catalogError = error.localizedDescription
            }
        }
    }

    public func project(for session: AgentSession) -> Project? {
        projects.first { $0.id == session.projectId }
    }

    /// Where a session's files live on the daemon host.
    public func cwd(for session: AgentSession) -> String? {
        if let worktree = session.workspace.worktreePath { return worktree }
        return project(for: session)?.path
    }

    // MARK: - Opening a session

    /// Hydrate and attach one session, returning the model that owns its
    /// projection. Calling it again for an already-open session returns the
    /// same model rather than refetching.
    @discardableResult
    public func open(_ sessionId: UUID) async throws -> SessionRuntimeModel {
        if let existing = open[sessionId] { return existing }
        let listed = sessions.first { $0.id == sessionId }
        let model = SessionRuntimeModel(session: listed ?? placeholder(sessionId))
        open[sessionId] = model
        model.beginCatchUp()
        do {
            try await hydrate(sessionId, into: model)
            try await attach(sessionId, model: model)
        } catch {
            model.endCatchUp()
            throw error
        }
        model.endCatchUp()
        refreshWorkspace(for: model.currentProjection, force: false)
        return model
    }

    /// Drop a session's projection. The daemon keeps running it; this is only
    /// the phone reclaiming the memory a transcript costs.
    public func close(_ sessionId: UUID) {
        open.removeValue(forKey: sessionId)
        refetching.remove(sessionId)
        buffered.removeValue(forKey: sessionId)
    }

    private func placeholder(_ sessionId: UUID) -> AgentSession {
        AgentSession(
            id: sessionId,
            projectId: .zero,
            provider: .unknown,
            createdAt: unixTime(),
            updatedAt: unixTime()
        )
    }

    private func hydrate(_ sessionId: UUID, into model: SessionRuntimeModel) async throws {
        let payload = try await request(.hydrateSession(sessionId: sessionId), sessionId: sessionId)
        guard case .session(let session) = payload else {
            throw ShidouSessionError.unexpectedResponse(expected: "session")
        }
        guard let session else { throw ShidouSessionError.projectNotFound }
        model.replaceSession(session)
    }

    private func attach(_ sessionId: UUID, model: SessionRuntimeModel) async throws {
        let payload = try await request(.attachSession, sessionId: sessionId)
        guard case .sessionRuntime(let runtimeId, let supportsSteer) = payload else {
            throw ShidouSessionError.unexpectedResponse(expected: "sessionRuntime")
        }
        model.setRuntime(id: runtimeId, supportsSteer: supportsSteer)
    }

    private func reattachOpenSessions() {
        for (sessionId, model) in open {
            Task { [weak self] in
                try? await self?.attach(sessionId, model: model)
            }
        }
    }

    // MARK: - Stale cursors

    /// The daemon's journal moved past our cursor: replay cannot make this
    /// session whole, so its transcript is refetched from the daemon's own
    /// record and the surviving tail is applied on top.
    private func beginRefetch(_ sessionId: UUID) {
        guard let model = open[sessionId] else {
            // Not open, so there is no projection to repair. Opening it later
            // hydrates from scratch, which is the same recovery.
            return
        }
        guard refetching.insert(sessionId).inserted else { return }
        model.beginCatchUp()
        Task { [weak self] in
            guard let self else { return }
            defer { self.finishRefetch(sessionId) }
            do {
                try await self.hydrate(sessionId, into: model)
            } catch {
                // A refetch that fails leaves the old projection in place and
                // drains the buffer onto it. The reducer skips events it has
                // already applied, so the result is at worst what replay alone
                // would have produced — never worse for having tried.
                model.lastDriverError = error.localizedDescription
            }
        }
    }

    private func finishRefetch(_ sessionId: UUID) {
        refetching.remove(sessionId)
        let pending = buffered.removeValue(forKey: sessionId) ?? []
        if let model = open[sessionId] {
            for event in pending { model.apply(event) }
            model.endCatchUp()
        }
    }

    // MARK: - Mutations

    /// Rename a task. The daemon merges keyed records, so sending only this
    /// session cannot disturb another client's catalog.
    public func rename(_ sessionId: UUID, to title: String) async throws {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var session = sessions.first(where: { $0.id == sessionId }) ?? open[sessionId]?.currentProjection
        else { throw ShidouSessionError.projectNotFound }
        session.title = trimmed.isEmpty ? AgentSession.defaultTitle : trimmed
        session.updatedAt = unixTime()
        applyLocally(session)
        try await persistAndWait(session)
    }

    public func delete(_ sessionId: UUID) async throws {
        _ = try await request(.removeSession, sessionId: sessionId)
        sessions.removeAll { $0.id == sessionId }
        close(sessionId)
        drafts.removeValue(forKey: sessionId)
        refreshCatalog()
    }

    public func setDraft(_ text: String, for sessionId: UUID) {
        if text.isEmpty {
            drafts.removeValue(forKey: sessionId)
        } else {
            drafts[sessionId] = text
        }
    }

    /// A task the user is about to start: local until it carries a prompt, so
    /// an abandoned New Task leaves nothing behind on the daemon.
    public func draftSession(projectId: UUID, provider: ProviderKind, isolated: Bool = false) -> AgentSession {
        newSession(projectId: projectId, provider: provider, isolated: isolated)
    }

    /// Mirror a session into the catalog row and the open projection, so the
    /// list and the transcript agree before the daemon answers.
    private func applyLocally(_ session: AgentSession) {
        if let index = sessions.firstIndex(where: { $0.id == session.id }) {
            sessions[index] = merged(listProjection: sessions[index], with: session)
        }
        open[session.id]?.replaceSession(session)
    }

    /// The catalog row carries no transcript, so a rename must not overwrite
    /// it with a hydrated session's messages — or the list would grow a copy
    /// of every open transcript.
    private func merged(listProjection: AgentSession, with session: AgentSession) -> AgentSession {
        var row = listProjection
        row.title = session.title
        row.autoTitle = session.autoTitle
        row.status = session.status
        row.updatedAt = session.updatedAt
        row.lastReplyAt = session.lastReplyAt
        return row
    }

    private func persist(_ session: AgentSession) {
        Task { [weak self] in
            try? await self?.persistAndWait(session)
        }
    }

    private func persistAndWait(_ session: AgentSession) async throws {
        _ = try await request(
            .saveTaskState(projects: [], liveSessionIds: [session.id], sessions: [session]),
            sessionId: session.id
        )
    }

    // MARK: - Workspace

    /// Resolve a session's branch and diff stat in the background, once per
    /// workspace, and store the answer. Nothing on a frame's path waits for
    /// it: the header renders without a subtitle until the result lands.
    public func refreshWorkspace(for session: AgentSession, force: Bool) {
        guard let cwd = cwd(for: session), !cwd.isEmpty else { return }
        // `force` skips the cache, never the in-flight guard: two probes racing
        // on one directory would have the first one's cleanup clear the marker
        // the second is still relying on.
        if !force, workspaces[cwd] != nil { return }
        guard workspaceProbes.insert(cwd).inserted else { return }
        Task { [weak self] in
            guard let self else { return }
            defer { self.workspaceProbes.remove(cwd) }
            guard case .workspace(.commitSnapshot(let snapshot)) =
                try? await self.request(.workspace(.inspectCommit(cwd: cwd)))
            else { return }
            self.workspaces[cwd] = snapshot
        }
    }

    public func workspace(for session: AgentSession) -> CommitSnapshot? {
        cwd(for: session).flatMap { workspaces[$0] }
    }

    // MARK: - Dispatch

    /// One place where a command becomes a correlated request, so every caller
    /// gets the same disconnected behaviour instead of inventing its own.
    private func request(
        _ command: Command,
        sessionId: UUID = .zero,
        runtimeId: UUID = .zero
    ) async throws -> ResponsePayload {
        let client = try await supervisor.currentClient()
        return try await client.request(command, sessionId: sessionId, runtimeId: runtimeId)
    }
}
