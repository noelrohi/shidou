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

    public internal(set) var projects: [Project] = []
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
    public internal(set) var open: [UUID: SessionRuntimeModel] = [:]
    /// Sessions whose replay came up short. Set the instant the daemon says so
    /// and cleared when the refetch lands; while set, events for that session
    /// are buffered rather than applied.
    public private(set) var refetching: Set<UUID> = []
    /// The most recent gap the daemon reported. Worth keeping rather than
    /// merely acting on: it is the one thing that explains why a transcript
    /// jumped, and the only evidence a client has that the phone was away
    /// longer than the daemon could remember.
    public private(set) var lastReplayGap: ReplayGap?

    /// Composer text and attachments typed but not sent. These are the
    /// daemon's drafts, not the phone's: they are loaded on connect and
    /// written back keyed, so what was typed here shows up in the browser and
    /// on the Mac — and so this client cannot delete a draft another one is
    /// still editing.
    public internal(set) var composerDrafts = ComposerDrafts()

    /// Git state per workspace directory, for the transcript header's
    /// branch and diff-stat subtitle. Refreshed in the background and read
    /// from the store on every frame — a miss means "not known yet".
    public private(set) var workspaces: [String: CommitSnapshot] = [:]

    /// Turn checkpoints the daemon still holds a ref for, per session. The
    /// transcript reads this every frame to decide which prompts can be sent
    /// again, so it is resolved once per session in the background and a miss
    /// means "not known yet" — never "no rewind".
    public internal(set) var turnRefs: [UUID: Set<Int>] = [:]
    /// The fork in flight for a session, so a second tap cannot open two.
    public internal(set) var forking: Set<UUID> = []
    /// The turn a rewind in flight is rewriting, per session.
    public internal(set) var rewinding: [UUID: Int] = [:]

    // MARK: Composer sources

    /// Daemon settings, needed before a provider can be probed or started.
    public internal(set) var settings: DaemonSettings?
    /// What each provider reports it can run: models, traits, agent presets.
    public internal(set) var probes: [ProviderKind: ProviderProbe] = [:]
    /// Branches per workspace directory, for the branch picker.
    public internal(set) var branches: [String: BranchSnapshot] = [:]
    /// The project's files, for `@file` completion.
    public internal(set) var projectFiles: [String: [FileEntry]] = [:]
    /// The project's slash commands, keyed by provider and directory.
    public internal(set) var slashCommands: [ComposerCommandKey: [SlashCommand]] = [:]
    /// Sessions whose provider process is coming up, so the composer can say
    /// so rather than look stuck.
    public internal(set) var starting: Set<UUID> = []

    /// The unanswered permission or question for every session, open or not.
    ///
    /// The store sees these on the wire whether or not a transcript is on
    /// screen, and a cold start replays them from the daemon's journal before
    /// the user has opened anything. Holding them here is what lets a task
    /// opened afterwards still show the prompt it is blocked on, and what lets
    /// a banner name a task the user is not looking at.
    public internal(set) var pendingInteractions: [UUID: PendingInteraction] = [:]

    // MARK: Wiring

    @ObservationIgnored let supervisor: ConnectionSupervisor
    @ObservationIgnored private var pump: Task<Void, Never>?
    @ObservationIgnored private var catalogTask: Task<Void, Never>?
    /// Events that arrived for a session while its refetch was in flight.
    @ObservationIgnored private var buffered: [UUID: [SequencedEvent]] = [:]
    /// Rejects a catalog load that a newer one has already superseded.
    @ObservationIgnored private var catalogGeneration = 0
    @ObservationIgnored private var workspaceProbes: Set<String> = []
    @ObservationIgnored private var pendingWorkspaceRefreshes: Set<String> = []
    /// Turn-ref loads in flight, so a republished projection cannot queue one
    /// request per frame.
    @ObservationIgnored var turnRefLoads: Set<UUID> = []
    /// One surfaces model per workspace directory, so the sheet and the iPad
    /// inspector read the same tree instead of each fetching their own.
    @ObservationIgnored var workspaceSurfaces: [String: WorkspaceSurfaces] = [:]

    // MARK: Composer wiring

    /// Draft writes are debounced per key, so a keystroke rate does not become
    /// a request rate.
    @ObservationIgnored var draftWrites: [ComposerDraftKey: Task<Void, Never>] = [:]
    @ObservationIgnored var draftGeneration: UInt64 = 0
    /// Steers awaiting the daemon's verdict, oldest first. `steerAccepted`
    /// turns one into a transcript message; `steerRejected` turns it back into
    /// a queued follow-up rather than losing what was typed.
    @ObservationIgnored var pendingSteers: [UUID: [PendingSteer]] = [:]
    /// Sends already in flight for a session, so a double-tap cannot open two
    /// turns against one runtime.
    @ObservationIgnored var sending: Set<UUID> = []
    /// Composer-source loads in flight, keyed the same way their results are.
    @ObservationIgnored var sourceLoads: Set<String> = []
    @ObservationIgnored var attentionSubscribers: [UUID: AsyncStream<AttentionEvent>.Continuation] =
        [:]
    /// The highest sequence each runtime has already raised attention for, so
    /// a reconnect's replay cannot notify twice about one permission.
    @ObservationIgnored var attentionWatermark: [AttentionWatermarkKey: UInt64] = [:]

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
        for write in draftWrites.values { write.cancel() }
        draftWrites.removeAll()
        open.removeAll()
        refetching.removeAll()
        buffered.removeAll()
        workspaces.removeAll()
        workspaceProbes.removeAll()
        pendingWorkspaceRefreshes.removeAll()
        workspaceSurfaces.removeAll()
        branches.removeAll()
        projectFiles.removeAll()
        slashCommands.removeAll()
        probes.removeAll()
        sourceLoads.removeAll()
        pendingSteers.removeAll()
        sending.removeAll()
        starting.removeAll()
        settings = nil
        pendingInteractions.removeAll()
        hasLoadedCatalog = false
        lastReplayGap = nil
        for subscriber in attentionSubscribers.values { subscriber.finish() }
        attentionSubscribers.removeAll()
        attentionWatermark.removeAll()
    }

    // MARK: - Supervised events

    private func handle(_ event: SupervisedEvent) {
        switch event {
        case .phase(.connected):
            refreshCatalog()
            refreshComposerDrafts()
            refreshOpenWorkspaces()
        case .reconnected:
            // Replayed events follow on this same stream, so the projections
            // catch up on their own. What cannot: the catalog, whose other
            // clients may have renamed or removed a task while we were away,
            // and the drafts, which they may have typed into.
            refreshCatalog()
            refreshComposerDrafts()
            refreshOpenWorkspaces()
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
        // Attention is raised before the projection is touched, and for every
        // session rather than only the open ones: the phone is told about a
        // permission on a task it is not looking at, which is the whole point
        // of the notification.
        raiseAttention(for: event)
        // A session mid-refetch is holding a projection with a hole in it.
        // Buffering rather than applying is what stops the tail from landing
        // on top of that hole and looking like a complete transcript.
        if refetching.contains(event.sessionId) {
            buffered[event.sessionId, default: []].append(event)
            return
        }
        guard let model = open[event.sessionId] else {
            reflectInCatalog(event)
            return
        }
        applySteerVerdict(event, to: model)
        let result = model.apply(event)
        guard let result else { return }
        reflectInCatalog(model.currentProjection)
        if result.settled || result.removeRuntime {
            persist(model.currentProjection)
            refreshWorkspace(for: model.currentProjection, force: true)
        }
        if result.settled {
            finishSettledTurn(model)
        }
        if result.removeRuntime {
            starting.remove(event.sessionId)
        }
    }

    // MARK: - Catalog

    /// The list reads catalog rows, not open projections, and the daemon only
    /// re-sends the catalog when a projection is persisted — which is at the
    /// end of a turn, not the start. So a turn that starts, blocks, or settles
    /// has to reach the row here, for every session: the second task working
    /// in the background is exactly the one the list exists to show.
    private func reflectInCatalog(_ event: SequencedEvent) {
        guard let index = sessions.firstIndex(where: { $0.id == event.sessionId }),
            !runtimeEventAlreadyApplied(session: sessions[index], event: event)
        else { return }
        reflectInCatalog(reduceRuntimeEvent(sessions[index], event).session)
    }

    private func reflectInCatalog(_ session: AgentSession) {
        guard let index = sessions.firstIndex(where: { $0.id == session.id }) else { return }
        let current = sessions[index]
        // Streaming text lands as one event per delta; the row only changes
        // when its state does, and `sessions` is observed by every list.
        guard current.status != session.status
            || current.lastReplyAt != session.lastReplyAt
            || current.turns.last != session.turns.last
            || current.title != session.title
            || current.autoTitle != session.autoTitle
            || current.archivedAt != session.archivedAt
        else { return }
        sessions[index] = merged(listProjection: current, with: session)
    }

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
        restorePendingInteraction(into: model)
        refreshWorkspace(for: model.currentProjection, force: false)
        return model
    }

    /// Drop a session's projection. The daemon keeps running it; this is only
    /// the phone reclaiming the memory a transcript costs.
    /// Re-attaches the prompt a session is blocked on to a projection that was
    /// just hydrated. Hydration returns the daemon's stored transcript, which
    /// records that the task is waiting but not what it is waiting on — that
    /// lives in the runtime journal this store has already been reading.
    private func restorePendingInteraction(into model: SessionRuntimeModel) {
        guard model.pendingPermission == nil, model.pendingUserInput == nil,
            let pending = pendingInteractions[model.currentProjection.id]
        else { return }
        switch pending {
        case .permission(let permission): model.restore(permission: permission)
        case .userInput(let userInput): model.restore(userInput: userInput)
        }
    }

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

    func hydrate(_ sessionId: UUID, into model: SessionRuntimeModel) async throws {
        let payload = try await request(.hydrateSession(sessionId: sessionId), sessionId: sessionId)
        guard case .session(let session) = payload else {
            throw ShidouSessionError.unexpectedResponse(expected: "session")
        }
        guard let session else { throw ShidouSessionError.projectNotFound }
        model.replaceSession(session)
    }

    func attach(_ sessionId: UUID, model: SessionRuntimeModel) async throws {
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

    /// Shelve a task, or take it back off the shelf.
    ///
    /// The daemon owns the archive rule and refuses while a task is Working or
    /// Waiting, so nothing is written here before it answers: on a refusal the
    /// call throws and the list is exactly as it was. The mark itself arrives
    /// with the catalog the daemon re-sends.
    public func setArchived(_ sessionId: UUID, archived: Bool) async throws {
        _ = try await request(.archiveSession(archived: archived), sessionId: sessionId)
        refreshCatalog()
    }

    public func delete(_ sessionId: UUID) async throws {
        _ = try await request(.removeSession, sessionId: sessionId)
        sessions.removeAll { $0.id == sessionId }
        close(sessionId)
        setDraft(ComposerDraft(), for: .session(sessionId: sessionId))
        refreshCatalog()
    }

    /// A task the user is about to start: local until it carries a prompt, so
    /// an abandoned New Task leaves nothing behind on the daemon.
    public func draftSession(projectId: UUID, provider: ProviderKind, isolated: Bool = false) -> AgentSession {
        newSession(projectId: projectId, provider: provider, isolated: isolated)
    }

    /// Mirror a session into the catalog row and the open projection, so the
    /// list and the transcript agree before the daemon answers.
    func applyLocally(_ session: AgentSession) {
        if let index = sessions.firstIndex(where: { $0.id == session.id }) {
            sessions[index] = merged(listProjection: sessions[index], with: session)
        } else if session.hasStarted {
            // A task started on this phone belongs in the list straight away:
            // waiting for the next catalog load would leave the user's own new
            // task missing from the screen they came from.
            sessions.insert(listProjection(of: session), at: 0)
        }
        open[session.id]?.replaceSession(session)
    }

    /// The catalog row for a session: everything the list reads, and none of
    /// the transcript it does not.
    private func listProjection(of session: AgentSession) -> AgentSession {
        var row = session
        row.messages = []
        row.transcriptBlocks = []
        row.turns = []
        row.queuedMessages = []
        return row
    }

    /// The catalog row carries no transcript, so a rename must not overwrite
    /// it with a hydrated session's messages — or the list would grow a copy
    /// of every open transcript. The latest turn does come along: it is what
    /// tells the row a turn is running, and one turn is not a transcript.
    private func merged(listProjection: AgentSession, with session: AgentSession) -> AgentSession {
        var row = listProjection
        row.title = session.title
        row.autoTitle = session.autoTitle
        row.status = session.status
        row.updatedAt = session.updatedAt
        row.lastReplyAt = session.lastReplyAt
        row.archivedAt = session.archivedAt
        row.runtimeEventCursor = session.runtimeEventCursor
        row.turns = Array(session.turns.suffix(1))
        return row
    }

    func persist(_ session: AgentSession) {
        Task { [weak self] in
            try? await self?.persistAndWait(session)
        }
    }

    func persistAndWait(_ session: AgentSession) async throws {
        var metadata = session
        // The daemon owns the canonical Projection. Phone saves still create
        // sessions and reconcile metadata and queue state, but never carry the
        // locally reduced transcript.
        metadata.messages = []
        metadata.transcriptBlocks = []
        metadata.turns = []
        _ = try await request(
            .saveTaskState(projects: [], liveSessionIds: [session.id], sessions: [metadata]),
            sessionId: session.id
        )
    }

    // MARK: - Workspace

    /// Resolve a session's branch and diff stat in the background, once per
    /// workspace, and store the answer. Nothing on a frame's path waits for
    /// it: the header renders without a subtitle until the result lands.
    public func refreshWorkspace(for session: AgentSession, force: Bool) {
        guard let cwd = cwd(for: session), !cwd.isEmpty else { return }
        refreshWorkspace(cwd: cwd, force: force)
    }

    private func refreshWorkspace(cwd: String, force: Bool) {
        if workspaceProbes.contains(cwd) {
            if force { pendingWorkspaceRefreshes.insert(cwd) }
            return
        }
        if !force, workspaces[cwd] != nil { return }
        workspaceProbes.insert(cwd)
        Task { [weak self] in
            guard let self else { return }
            let payload = try? await self.request(.workspace(.inspectCommit(cwd: cwd)))
            self.workspaceProbes.remove(cwd)
            if case .workspace(.commitSnapshot(let snapshot)) = payload {
                self.setWorkspaceSnapshot(snapshot, for: cwd)
            }
            if self.pendingWorkspaceRefreshes.remove(cwd) != nil {
                self.refreshWorkspace(cwd: cwd, force: true)
            }
        }
    }

    public func refreshOpenWorkspaces() {
        for model in open.values {
            refreshWorkspace(for: model.currentProjection, force: true)
        }
    }

    public func workspace(for session: AgentSession) -> CommitSnapshot? {
        cwd(for: session).flatMap { workspaces[$0] }
    }

    func setWorkspaceSnapshot(_ snapshot: CommitSnapshot, for cwd: String) {
        workspaces[cwd] = snapshot
        workspaceSurfaces[cwd]?.workspaceDidChange()
    }

    // MARK: - Dispatch

    /// One place where a command becomes a correlated request, so every caller
    /// gets the same disconnected behaviour instead of inventing its own.
    func request(
        _ command: Command,
        sessionId: UUID = .zero,
        runtimeId: UUID = .zero
    ) async throws -> ResponsePayload {
        let client = try await supervisor.currentClient()
        return try await client.request(command, sessionId: sessionId, runtimeId: runtimeId)
    }
}
