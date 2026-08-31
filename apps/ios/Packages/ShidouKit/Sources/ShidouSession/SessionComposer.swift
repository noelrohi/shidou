import Foundation
import ShidouClient
import ShidouProtocol

// Everything the composer says to the daemon, ported from
// `apps/web/src/lib/runtime-context.tsx` and the composer half of
// `daemon-api.ts`.
//
// It lives on the store rather than in a view for the same reason the store
// exists at all: sending a prompt is a conversation — attach, probe,
// materialize a worktree, checkpoint, persist, start, prompt — and every step
// of it has to survive the screen that started it being dismissed.

/// Slash commands are discovered per provider *and* per directory: the same
/// project answers differently for Claude and for Codex.
public struct ComposerCommandKey: Hashable, Sendable {
    public var provider: ProviderKind
    public var cwd: String

    public init(provider: ProviderKind, cwd: String) {
        self.provider = provider
        self.cwd = cwd
    }
}

/// What the user typed, and what the provider will actually receive.
///
/// The two differ whenever attachments are staged or a slash command expands,
/// and every path that sends — a prompt, a steer, a queued follow-up the turn
/// released — has to compose them the same way or the transcript and the
/// provider stop agreeing about what was asked.
public struct ComposerSubmission: Sendable {
    public var displayContent: String
    public var providerPrompt: String
    public var attachments: [MessageAttachment]

    public init(
        prompt: String,
        attachments: [MessageAttachment],
        providerPromptOverride: String? = nil
    ) {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        self.displayContent = trimmed
        self.attachments = attachments
        self.providerPrompt = providerPromptOverride?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            ?? [trimmed, attachments.map { "@\($0.mention)" }.joined(separator: " ")]
                .filter { !$0.isEmpty }
                .joined(separator: " ")
    }

    public var isEmpty: Bool { displayContent.isEmpty && attachments.isEmpty }
}

/// A steer the daemon has not ruled on yet.
public struct PendingSteer: Sendable {
    public var providerPrompt: String
    public var displayContent: String
    public var attachments: [MessageAttachment]
}

/// The three events the notifications decision calls worth interrupting for.
public enum AttentionEvent: Sendable {
    case turnFinished(sessionId: UUID, success: Bool, summary: String?)
    case permission(sessionId: UUID, requestId: String, title: String)
    case userInputRequested(sessionId: UUID, requestId: String, header: String)

    public var sessionId: UUID {
        switch self {
        case .turnFinished(let sessionId, _, _): return sessionId
        case .permission(let sessionId, _, _): return sessionId
        case .userInputRequested(let sessionId, _, _): return sessionId
        }
    }

    /// The two that block the agent until the user answers. Only these earn an
    /// in-app banner while the app is open.
    public var isBlocking: Bool {
        if case .turnFinished = self { return false }
        return true
    }
}

/// What a session is blocked on, tracked for every session rather than only
/// the open ones.
public enum PendingInteraction: Sendable {
    case permission(PendingPermission)
    case userInput(PendingUserInput)

    public var requestId: String {
        switch self {
        case .permission(let permission): return permission.requestId
        case .userInput(let userInput): return userInput.requestId
        }
    }
}

public struct AttentionWatermarkKey: Hashable, Sendable {
    public var sessionId: UUID
    public var runtimeId: UUID
    public var epoch: UUID
}

extension SessionStore {
    // MARK: - Attention

    /// Attention events, for local notifications and in-app banners. The
    /// stream is deliberately not the event stream: a notification is about
    /// three kinds out of thirty, and a consumer should not have to know the
    /// wire to find them.
    public func attentionEvents() -> AsyncStream<AttentionEvent> {
        let id = UUID()
        return AsyncStream { continuation in
            attentionSubscribers[id] = continuation
            continuation.onTermination = { _ in
                Task { @MainActor [weak self] in
                    self?.attentionSubscribers.removeValue(forKey: id)
                }
            }
        }
    }

    func raiseAttention(for event: SequencedEvent) {
        let key = AttentionWatermarkKey(
            sessionId: event.sessionId, runtimeId: event.runtimeId, epoch: event.epoch)
        // Replay re-delivers everything past our cursor, and a phone that came
        // back from the Grace Window is exactly the client that gets a replay.
        // Notifying twice about one permission is the failure this prevents.
        if let seen = attentionWatermark[key], seen >= event.sequence { return }
        attentionWatermark[key] = event.sequence

        let attention: AttentionEvent?
        switch DriverEvent(wire: event.event) {
        case .turnFinished(let success, let summary):
            pendingInteractions.removeValue(forKey: event.sessionId)
            attention = .turnFinished(
                sessionId: event.sessionId, success: success, summary: summary)
        case .permission(let requestId, let title, let detail, let options):
            pendingInteractions[event.sessionId] = .permission(PendingPermission(
                requestId: requestId, title: title, detail: detail, options: options))
            attention = .permission(
                sessionId: event.sessionId, requestId: requestId, title: title)
        case .userInputRequested(let requestId, let questions):
            pendingInteractions[event.sessionId] = .userInput(
                PendingUserInput(requestId: requestId, questions: questions))
            attention = .userInputRequested(
                sessionId: event.sessionId,
                requestId: requestId,
                header: questions.first?.header ?? questions.first?.question ?? ""
            )
        case .interactionResolved(let requestId):
            if pendingInteractions[event.sessionId]?.requestId == requestId {
                pendingInteractions.removeValue(forKey: event.sessionId)
            }
            attention = nil
        default:
            attention = nil
        }
        guard let attention else { return }
        for subscriber in attentionSubscribers.values { subscriber.yield(attention) }
    }

    /// The title to put on a notification about one session.
    public func title(for sessionId: UUID) -> String {
        if let model = open[sessionId] { return displayTitle(model.session) }
        if let row = sessions.first(where: { $0.id == sessionId }) { return displayTitle(row) }
        return AgentSession.defaultTitle
    }

    // MARK: - Steering verdicts

    /// The daemon's answer to a steer, applied before the reducer sees the
    /// event. Neither reducer knows about steering — both clients resolve it
    /// here, against the queue of steers they sent.
    func applySteerVerdict(_ event: SequencedEvent, to model: SessionRuntimeModel) {
        switch DriverEvent(wire: event.event) {
        case .steerAccepted(let message):
            guard var pending = pendingSteers[event.sessionId], !pending.isEmpty else { return }
            let steer = pending.removeFirst()
            pendingSteers[event.sessionId] = pending
            var session = model.currentProjection
            let carriesDisplay =
                !steer.attachments.isEmpty || steer.providerPrompt != steer.displayContent
            session.messages.append(Message(
                turnId: session.turns.last?.id,
                role: .user,
                content: message.isEmpty ? steer.providerPrompt : message,
                displayContent: carriesDisplay ? steer.displayContent : nil,
                attachments: steer.attachments,
                createdAt: unixTime()
            ))
            model.replaceSession(session)
        case .steerRejected:
            guard var pending = pendingSteers[event.sessionId], !pending.isEmpty else { return }
            let steer = pending.removeFirst()
            pendingSteers[event.sessionId] = pending
            // A rejected steer is not a lost message: it becomes the follow-up
            // it would have been had the user waited.
            let session = queueSubmission(
                model.currentProjection,
                displayContent: steer.displayContent,
                providerPrompt: steer.providerPrompt,
                attachments: steer.attachments
            )
            model.replaceSession(session)
            persist(session)
        default:
            break
        }
    }

    // MARK: - Settled turns

    /// Capture the turn's checkpoint, then start whatever was queued behind
    /// it. Both are the desktop's and the browser's behaviour; a phone that
    /// skipped either would leave a task the other clients read as broken.
    func finishSettledTurn(_ model: SessionRuntimeModel) {
        Task { [weak self] in
            guard let self else { return }
            await self.captureSettledCheckpoint(model)
            await self.drainQueue(model)
        }
    }

    private func captureSettledCheckpoint(_ model: SessionRuntimeModel) async {
        var session = model.currentProjection
        guard
            let index = session.turns.lastIndex(where: {
                $0.status != .running && $0.checkpoint == nil
            }),
            let cwd = cwd(for: session), !cwd.isEmpty
        else { return }
        let turnCount = session.turns[index].turnCount
        var checkpoint: Checkpoint
        if case .workspace(.checkpoint(let captured))? = try? await request(
            .workspace(.captureTurn(cwd: cwd, sessionId: session.id, turnCount: turnCount)))
        {
            checkpoint = captured
        } else {
            checkpoint = Checkpoint(
                turnCount: turnCount,
                gitRef: CheckpointRefs.turnRef(sessionId: session.id, turnCount: turnCount),
                status: .error,
                files: [],
                additions: 0,
                deletions: 0,
                createdAt: unixTime()
            )
        }
        session = model.currentProjection
        guard let latest = session.turns.firstIndex(where: { $0.turnCount == turnCount })
        else { return }
        session.turns[latest].checkpoint = checkpoint
        model.replaceSession(session)
        try? await persistAndWait(session)
    }

    private func drainQueue(_ model: SessionRuntimeModel) async {
        var session = model.currentProjection
        guard session.status == .idle, let next = session.queuedMessages.first else { return }
        session.queuedMessages.removeFirst()
        model.replaceSession(session)
        try? await persistAndWait(session)
        try? await send(
            prompt: next.displayContent ?? next.content,
            attachments: next.attachments,
            to: model,
            providerPromptOverride: next.content
        )
    }

    // MARK: - Drafts

    /// Loads every draft the daemon holds. Called on connect and on reconnect,
    /// because another client may have typed while we were away.
    public func refreshComposerDrafts() {
        Task { [weak self] in
            guard let self else { return }
            guard case .composerDrafts(let drafts)? = try? await self.request(.loadComposerDrafts)
            else { return }
            self.mergeRemoteDrafts(drafts)
        }
    }

    /// Remote drafts do not clobber a key this phone is still writing: the
    /// pending write is the newer edit, and losing a half-typed prompt to a
    /// reconnect is exactly the thing server-synced drafts must not do.
    private func mergeRemoteDrafts(_ remote: ComposerDrafts) {
        var merged = remote
        for key in draftWrites.keys {
            merged[key] = composerDrafts[key]
        }
        composerDrafts = merged
    }

    public func draft(for key: ComposerDraftKey) -> ComposerDraft {
        composerDrafts.draft(for: key)
    }

    /// Records a draft locally and schedules the keyed write. Typing is not a
    /// request rate: the write lands a beat after the last keystroke.
    public func setDraft(_ draft: ComposerDraft, for key: ComposerDraftKey) {
        guard let change = composerDrafts.setDraft(draft, for: key) else { return }
        draftWrites[key]?.cancel()
        draftWrites[key] = Task { [weak self] in
            try? await Task.sleep(for: Self.draftWriteDelay)
            guard let self, !Task.isCancelled else { return }
            self.draftWrites.removeValue(forKey: key)
            _ = try? await self.request(.applyComposerDraftChanges(changes: [change]))
        }
    }

    /// Carries a draft when an unstarted task acquires an identity — its
    /// project changes, or it becomes a real session.
    public func moveDraft(from source: ComposerDraftKey, to destination: ComposerDraftKey) {
        let changes = composerDrafts.moveToEmpty(from: source, to: destination)
        guard !changes.isEmpty else { return }
        Task { [weak self] in
            _ = try? await self?.request(.applyComposerDraftChanges(changes: changes))
        }
    }

    /// Replaces the whole draft file. The keyed path is what ordinary typing
    /// uses; this exists for the one case that is genuinely whole-file.
    public func replaceAllDrafts(_ drafts: ComposerDrafts) async throws {
        draftGeneration &+= 1
        composerDrafts = drafts
        _ = try await request(.saveComposerDrafts(drafts: drafts, generation: draftGeneration))
    }

    static let draftWriteDelay: Duration = .milliseconds(600)

    // MARK: - Composer sources

    /// Daemon settings, cached for the connection. A provider cannot be probed
    /// or started without them: they carry the binary overrides.
    @discardableResult
    public func loadSettings() async throws -> DaemonSettings {
        if let settings { return settings }
        guard case .settings(let loaded) = try await request(.getSettings) else {
            throw ShidouSessionError.unexpectedResponse(expected: "settings")
        }
        settings = loaded
        return loaded
    }

    @discardableResult
    public func loadProbe(_ provider: ProviderKind) async throws -> ProviderProbe {
        if let probe = probes[provider] { return probe }
        let settings = try await loadSettings()
        guard case .providerProbe(let probe, _) = try await request(.probeProvider(
            provider: provider,
            binaryOverride: settings.providerBinaryOverrides[provider.rawValue],
            discoverModels: true,
            probeVersion: false
        )) else {
            throw ShidouSessionError.unexpectedResponse(expected: "providerProbe")
        }
        probes[provider] = probe
        return probe
    }

    /// Probe a provider in the background so the model picker has something to
    /// show. A miss means "not known yet"; nothing on a frame waits for it.
    public func refreshProbe(_ provider: ProviderKind) {
        guard probes[provider] == nil, sourceLoads.insert("probe:\(provider.rawValue)").inserted
        else { return }
        Task { [weak self] in
            guard let self else { return }
            defer { self.sourceLoads.remove("probe:\(provider.rawValue)") }
            _ = try? await self.loadProbe(provider)
        }
    }

    /// Probe everything the daemon has not disabled, for the model picker's
    /// provider tabs.
    public func refreshAllProbes() {
        Task { [weak self] in
            guard let self, let settings = try? await self.loadSettings() else { return }
            for provider in ProviderKind.selectable where
                !settings.disabledProviders.contains(provider)
            {
                self.refreshProbe(provider)
            }
        }
    }

    /// The provider's plan limits, for the usage sheet. Fetched on demand: it
    /// costs the daemon a call to the provider, so nothing loads it eagerly.
    public func planUsage(for provider: ProviderKind) async throws -> PlanUsage? {
        let settings = try await loadSettings()
        guard case .planUsage(let usage) = try await request(.fetchPlanUsage(
            provider: provider,
            binaryOverride: settings.providerBinaryOverrides[provider.rawValue],
            cliVersion: nil
        )) else {
            throw ShidouSessionError.unexpectedResponse(expected: "planUsage")
        }
        return usage
    }

    public func refreshBranches(cwd: String, force: Bool = false) {
        guard !cwd.isEmpty else { return }
        if !force, branches[cwd] != nil { return }
        guard sourceLoads.insert("branches:\(cwd)").inserted else { return }
        Task { [weak self] in
            guard let self else { return }
            defer { self.sourceLoads.remove("branches:\(cwd)") }
            guard case .workspace(.branches(let snapshot))? = try? await self.request(
                .workspace(.inspectBranches(cwd: cwd)))
            else { return }
            self.branches[cwd] = snapshot
        }
    }

    public func refreshProjectFiles(cwd: String, force: Bool = false) {
        guard !cwd.isEmpty else { return }
        if !force, projectFiles[cwd] != nil { return }
        guard sourceLoads.insert("files:\(cwd)").inserted else { return }
        Task { [weak self] in
            guard let self else { return }
            defer { self.sourceLoads.remove("files:\(cwd)") }
            guard case .workspace(.projectFiles(let entries))? = try? await self.request(
                .workspace(.listProjectFiles(cwd: cwd)))
            else { return }
            self.projectFiles[cwd] = entries
        }
    }

    public func refreshSlashCommands(provider: ProviderKind, cwd: String, force: Bool = false) {
        guard !cwd.isEmpty else { return }
        let key = ComposerCommandKey(provider: provider, cwd: cwd)
        if !force, slashCommands[key] != nil { return }
        guard sourceLoads.insert("commands:\(provider.rawValue):\(cwd)").inserted else { return }
        Task { [weak self] in
            guard let self else { return }
            defer { self.sourceLoads.remove("commands:\(provider.rawValue):\(cwd)") }
            guard case .workspace(.slashCommands(let commands))? = try? await self.request(
                .workspace(.discoverSlashCommands(provider: provider, projectRoot: cwd)))
            else { return }
            self.slashCommands[key] = commands
        }
    }

    /// Everything the composer completes and picks from, for one session.
    public func refreshComposerSources(for session: AgentSession) {
        refreshProbe(session.provider)
        guard let cwd = cwd(for: session), !cwd.isEmpty else { return }
        refreshBranches(cwd: cwd)
        refreshProjectFiles(cwd: cwd)
        refreshSlashCommands(provider: session.provider, cwd: cwd)
    }

    /// The merged command list for a session: what the daemon found on disk,
    /// plus what the live provider process has reported.
    public func commands(for session: AgentSession) -> [SlashCommand] {
        let discovered = cwd(for: session)
            .map { ComposerCommandKey(provider: session.provider, cwd: $0) }
            .flatMap { slashCommands[$0] } ?? []
        return ComposerAutocomplete.mergeCommands(
            discovered: discovered, reported: session.availableCommands)
    }

    public func files(for session: AgentSession) -> [FileEntry] {
        cwd(for: session).flatMap { projectFiles[$0] } ?? []
    }

    public func branchSnapshot(for session: AgentSession) -> BranchSnapshot? {
        cwd(for: session).flatMap { branches[$0] }
    }

    public func checkoutBranch(cwd: String, branch: String, create: Bool) async throws {
        guard case .workspace(.branchChanged(let snapshot)) = try await request(
            .workspace(.checkoutBranch(cwd: cwd, branch: branch, create: create)))
        else {
            throw ShidouSessionError.unexpectedResponse(expected: "branchChanged")
        }
        branches[cwd] = snapshot
        refreshWorkspaceDirectory(cwd)
    }

    private func refreshWorkspaceDirectory(_ cwd: String) {
        Task { [weak self] in
            guard let self,
                case .workspace(.commitSnapshot(let snapshot))? = try? await self.request(
                    .workspace(.inspectCommit(cwd: cwd)))
            else { return }
            self.setWorkspaceSnapshot(snapshot, for: cwd)
        }
    }

    // MARK: - Browsing the daemon's filesystem

    public func browseDirectory(path: String?) async throws -> DaemonDirectory {
        guard case .workspace(.directory(let directory)) = try await request(
            .workspace(.browseDirectory(path: path)))
        else {
            throw ShidouSessionError.unexpectedResponse(expected: "directory")
        }
        return directory
    }

    // MARK: - Projects

    /// Adds a project at a daemon-host path, or returns the one already there.
    /// Saves merge, so sending the whole project list back cannot drop what
    /// another client added while this screen was open.
    @discardableResult
    public func addProject(path: String) async throws -> Project {
        let candidate = try newProject(path: path)
        return try await persistProject(candidate)
    }

    /// A scratch workspace: the daemon makes the directory, and the project
    /// that points at it is the "No project" one.
    @discardableResult
    public func createProjectlessProject() async throws -> Project {
        guard case .workspace(.projectlessWorkspace(let cwd)) = try await request(
            .workspace(.createProjectlessWorkspace(prompt: nil)))
        else {
            throw ShidouSessionError.unexpectedResponse(expected: "projectlessWorkspace")
        }
        var candidate = try newProject(path: cwd)
        candidate.name = Project.projectlessName
        return try await persistProject(candidate)
    }

    private func persistProject(_ candidate: Project) async throws -> Project {
        guard case .taskState(let existingProjects, let existingSessions, _, _) =
            try await request(.loadTaskState)
        else {
            throw ShidouSessionError.unexpectedResponse(expected: "taskState")
        }
        if let existing = existingProjects.first(where: { $0.path == candidate.path }) {
            projects = existingProjects
            return existing
        }
        let merged = existingProjects + [candidate]
        _ = try await request(.saveTaskState(
            projects: merged,
            liveSessionIds: existingSessions.map(\.id),
            sessions: []
        ))
        projects = merged
        return candidate
    }

    // MARK: - Session options

    /// Persists a composer choice. A live runtime is re-tuned in place where
    /// it can be; a change it cannot absorb — a different provider or agent
    /// preset — closes the runtime so the next prompt starts a correct one.
    public func saveSession(_ session: AgentSession) async throws {
        let previous = open[session.id]?.currentProjection
            ?? sessions.first { $0.id == session.id }
        var next = session
        next.updatedAt = unixTime()
        applyLocally(next)

        if let model = open[session.id], let runtimeId = model.runtimeId {
            let needsReset =
                previous.map {
                    $0.provider != next.provider || $0.agentPreset != next.agentPreset
                } ?? false
            if needsReset {
                _ = try? await request(
                    .closeSession, sessionId: next.id, runtimeId: runtimeId)
                model.clearRuntime()
            } else {
                let applied = try? await request(
                    .applyOptions(SessionOptions(session: next)),
                    sessionId: next.id,
                    runtimeId: runtimeId
                )
                if case .optionsApplied(true) = applied {
                    // The runtime took the change; nothing else to do.
                } else {
                    _ = try? await request(
                        .closeSession, sessionId: next.id, runtimeId: runtimeId)
                    model.clearRuntime()
                }
            }
        }
        try await persistAndWait(next)
    }

    /// Registers a locally created draft task so the composer has a model to
    /// work against. Unlike `open(_:)` this never hydrates: there is nothing
    /// on the daemon to hydrate from until the first prompt.
    @discardableResult
    public func adopt(_ session: AgentSession) -> SessionRuntimeModel {
        if let existing = open[session.id] {
            return existing
        }
        let model = SessionRuntimeModel(session: session)
        open[session.id] = model
        return model
    }

    // MARK: - Sending

    /// Sends one prompt, or queues it behind the turn already running.
    ///
    /// Everything a first prompt needs happens here in order: the worktree is
    /// materialized, the pre-turn checkpoint captured, the task persisted, the
    /// provider started, and only then does the prompt go out. A failure at
    /// any step ends the turn visibly instead of leaving a task that looks
    /// like it is thinking.
    public func send(
        prompt rawPrompt: String,
        attachments: [MessageAttachment] = [],
        to model: SessionRuntimeModel,
        providerPromptOverride: String? = nil
    ) async throws {
        try await send(
            ComposerSubmission(
                prompt: rawPrompt,
                attachments: attachments,
                providerPromptOverride: providerPromptOverride
            ),
            to: model
        )
    }

    public func send(_ submission: ComposerSubmission, to model: SessionRuntimeModel) async throws {
        guard !submission.isEmpty else { return }
        let prompt = submission.displayContent
        let attachments = submission.attachments
        let providerPrompt = submission.providerPrompt

        let current = model.currentProjection
        if current.status.isBusy || sending.contains(current.id) {
            let queued = queueSubmission(
                current,
                displayContent: prompt,
                providerPrompt: providerPrompt,
                attachments: attachments
            )
            model.replaceSession(queued)
            applyLocally(queued)
            try await persistAndWait(queued)
            return
        }

        sending.insert(current.id)
        defer { sending.remove(current.id) }

        var session = beginTurn(current, prompt: prompt, attachments: attachments)
        model.replaceSession(session)
        applyLocally(session)

        var startup: (probe: ProviderProbe, binary: String)?
        do {
            guard let project = projects.first(where: { $0.id == session.projectId }) else {
                throw ShidouSessionError.projectNotFound
            }
            if model.runtimeId == nil {
                let probe = try await loadProbe(session.provider)
                guard probe.installed, let binary = probe.path, !binary.isEmpty else {
                    throw ShidouSessionError.providerNotInstalled(session.provider)
                }
                startup = (probe, binary)
            }
            session = try await materializeWorktree(
                session,
                project: project,
                prompt: prompt.isEmpty ? (attachments.first?.name ?? "task") : prompt
            )
            model.replaceSession(session)
            if let turnCount = session.turns.last?.turnCount {
                // Best effort: a workspace with no Git repository has no
                // checkpoint to take, and that must not stop the turn.
                _ = try? await request(.workspace(.captureTurnStart(
                    cwd: sessionCwd(session, project: project),
                    sessionId: session.id,
                    turnCount: turnCount
                )))
            }
            try await persistAndWait(session)
            applyLocally(session)
        } catch {
            model.replaceSession(current)
            applyLocally(current)
            throw error
        }

        do {
            var runtimeId = model.runtimeId
            if let startup {
                guard let project = projects.first(where: { $0.id == session.projectId }) else {
                    throw ShidouSessionError.projectNotFound
                }
                let id = UUID()
                starting.insert(session.id)
                defer { starting.remove(session.id) }
                let response = try await request(
                    .start(options: DriverStartOptions(
                        provider: session.provider.rawValue,
                        binary: startup.binary,
                        cwd: sessionCwd(session, project: project),
                        mode: session.runtimeMode,
                        interactionMode: session.interactionMode,
                        model: session.model,
                        reasoningEffort: session.reasoningEffort,
                        serviceTier: session.serviceTier,
                        contextWindow: session.contextWindow,
                        agentPreset: session.agentPreset,
                        computerUseEnabled: false,
                        providerCursor: session.providerCursor
                    )),
                    sessionId: session.id,
                    runtimeId: id
                )
                guard case .started(let supportsSteer) = response else {
                    throw ShidouSessionError.unexpectedResponse(expected: "started")
                }
                model.setRuntime(id: id, supportsSteer: supportsSteer)
                runtimeId = id
            }
            guard let runtimeId else { throw ShidouSessionError.noLiveRuntime }
            guard let submissionId = session.turns.last?.id else {
                throw ShidouSessionError.noLiveRuntime
            }
            _ = try await request(
                .prompt(providerPrompt, submissionId: submissionId),
                sessionId: session.id,
                runtimeId: runtimeId
            )
        } catch {
            model.clearRuntime()
            failTurn(model, summary: error.localizedDescription)
            throw error
        }
    }

    /// Steers the running turn, or falls back to an ordinary send when there
    /// is no turn to steer — a busy task then queues, which is what the user
    /// meant either way.
    public func steer(
        prompt rawPrompt: String,
        attachments: [MessageAttachment] = [],
        to model: SessionRuntimeModel,
        providerPromptOverride: String? = nil
    ) async throws {
        try await steer(
            ComposerSubmission(
                prompt: rawPrompt,
                attachments: attachments,
                providerPromptOverride: providerPromptOverride
            ),
            to: model
        )
    }

    public func steer(_ submission: ComposerSubmission, to model: SessionRuntimeModel) async throws {
        guard !submission.isEmpty else { return }
        let session = model.currentProjection
        guard let runtimeId = model.runtimeId, model.supportsSteer, session.hasActiveProviderTurn
        else {
            try await send(submission, to: model)
            return
        }
        pendingSteers[session.id, default: []].append(PendingSteer(
            providerPrompt: submission.providerPrompt,
            displayContent: submission.displayContent,
            attachments: submission.attachments
        ))
        _ = try await request(
            .steer(submission.providerPrompt), sessionId: session.id, runtimeId: runtimeId)
    }

    public func cancel(_ model: SessionRuntimeModel) async throws {
        guard let runtimeId = model.runtimeId else { throw ShidouSessionError.noLiveRuntime }
        _ = try await request(
            .cancel, sessionId: model.currentProjection.id, runtimeId: runtimeId)
    }

    public func respond(
        _ model: SessionRuntimeModel,
        requestId: String,
        optionId: String
    ) async throws {
        guard let runtimeId = model.runtimeId else { throw ShidouSessionError.noLiveRuntime }
        _ = try await request(
            .respond(requestId: requestId, optionId: optionId),
            sessionId: model.currentProjection.id,
            runtimeId: runtimeId
        )
        pendingInteractions.removeValue(forKey: model.currentProjection.id)
        model.clearPendingPermission()
    }

    public func respondUserInput(
        _ model: SessionRuntimeModel,
        requestId: String,
        answers: [UserInputAnswer]
    ) async throws {
        guard let runtimeId = model.runtimeId else { throw ShidouSessionError.noLiveRuntime }
        _ = try await request(
            .respondUserInput(requestId: requestId, answers: answers),
            sessionId: model.currentProjection.id,
            runtimeId: runtimeId
        )
        pendingInteractions.removeValue(forKey: model.currentProjection.id)
        model.clearPendingUserInput()
    }

    public func removeQueuedMessage(_ model: SessionRuntimeModel, messageId: UUID) async throws {
        var session = model.currentProjection
        session.queuedMessages.removeAll { $0.id == messageId }
        session.updatedAt = unixTime()
        model.replaceSession(session)
        applyLocally(session)
        try await persistAndWait(session)
    }

    // MARK: - Attachments

    /// An image from Photos or the camera, copied into the daemon's blob store
    /// so the provider reads it from the host rather than from the phone.
    public func attachImage(
        data: Data,
        mimeType: String,
        name: String
    ) async throws -> MessageAttachment {
        guard data.count <= AttachmentLimits.maxUploadBytes else {
            throw ShidouSessionError.attachmentTooLarge(name)
        }
        guard case .blobStored(let reference, let path) = try await request(
            .storeBlob(mimeType: mimeType, bytes: data))
        else {
            throw ShidouSessionError.unexpectedResponse(expected: "blobStored")
        }
        return MessageAttachment(
            path: path,
            mention: path,
            name: name,
            isDir: false,
            isImage: true,
            blobReference: reference
        )
    }

    /// A file or directory that already lives on the daemon host, picked out
    /// of the file browser or completed with `@`.
    public func attachDaemonPath(_ path: String) async throws -> MessageAttachment {
        guard case .attachmentStored(let stored) = try await request(
            .importPathAttachment(path: path))
        else {
            throw ShidouSessionError.unexpectedResponse(expected: "attachmentStored")
        }
        let mention = stored.isDir && !path.hasSuffix("/") ? path + "/" : path
        return MessageAttachment(
            path: stored.path,
            mention: mention,
            name: stored.name,
            isDir: stored.isDir,
            isImage: !stored.isDir && MessageAttachment.isImageName(stored.name),
            blobReference: stored.reference
        )
    }

    /// The bytes behind an attachment, for the composer's thumbnail.
    public func attachmentData(_ attachment: MessageAttachment) async throws -> Data {
        guard let reference = attachment.blobReference else {
            throw ShidouSessionError.unexpectedResponse(expected: "blobData")
        }
        let command: Command = reference.hasPrefix(AttachmentLimits.blobScheme)
            ? .readBlob(reference: reference)
            : .readAttachment(reference: reference, path: attachment.path)
        guard case .blobData(let data) = try await request(command) else {
            throw ShidouSessionError.unexpectedResponse(expected: "blobData")
        }
        return data
    }

    /// The bytes behind a transcript image, which a provider reports either as
    /// a stored blob or as a path on the daemon host.
    public func imageData(reference: String) async throws -> Data {
        let command: Command = reference.hasPrefix(AttachmentLimits.blobScheme)
            ? .readBlob(reference: reference)
            : .readAttachment(reference: reference, path: reference)
        guard case .blobData(let data) = try await request(command) else {
            throw ShidouSessionError.unexpectedResponse(expected: "blobData")
        }
        return data
    }

    /// The bytes behind a file on the daemon host, imported once so the phone
    /// can read it back the same way it reads any attachment.
    public func imageData(daemonPath path: String) async throws -> Data {
        guard case .attachmentStored(let attachment) = try await request(
            .importPathAttachment(path: path)
        ) else {
            throw ShidouSessionError.unexpectedResponse(expected: "attachmentStored")
        }
        guard case .blobData(let data) = try await request(
            .readAttachment(reference: attachment.reference, path: attachment.path)
        ) else {
            throw ShidouSessionError.unexpectedResponse(expected: "blobData")
        }
        return data
    }

    // MARK: - Worktrees

    /// Turns a planned worktree into a real one. This is the moment a task
    /// stops being a plan: before the first prompt reaches a provider, and
    /// before any checkpoint can be taken against the wrong directory.
    func materializeWorktree(
        _ session: AgentSession,
        project: Project,
        prompt: String
    ) async throws -> AgentSession {
        guard case .newWorktree(let baseBranch) = session.workspace else { return session }
        guard case .workspace(.worktreeCreated(let worktree)) = try await request(
            .workspace(.createWorktree(
                projectPath: project.path,
                projectId: project.id,
                sessionId: session.id,
                prompt: prompt,
                baseBranch: baseBranch
            )))
        else {
            throw ShidouSessionError.unexpectedResponse(expected: "worktreeCreated")
        }
        var next = session
        next.workspace = .worktree(path: worktree.path, branch: worktree.branch)
        return next
    }

    // MARK: - Failure

    /// Ends a turn that never reached the provider, through the same reducer
    /// path a real `turnFinished` takes — so the transcript says what happened
    /// rather than spinning forever.
    private func failTurn(_ model: SessionRuntimeModel, summary: String) {
        let session = model.currentProjection
        let cursor = session.runtimeEventCursor
        var result = reduceRuntimeEvent(
            session,
            SequencedEvent(
                sessionId: session.id,
                runtimeId: model.runtimeId ?? .zero,
                epoch: .zero,
                sequence: 0,
                event: WireDriverEvent(
                    kind: "turnFinished",
                    payload: .object(["success": .bool(false), "summary": .string(summary)])
                )
            )
        )
        // The synthetic event never came from the daemon, so it must not move
        // the cursor that decides which real events are still new.
        result.session.runtimeEventCursor = cursor
        model.replaceSession(result.session)
        applyLocally(result.session)
        persist(result.session)
    }
}

extension WorkspaceOperation {
    /// The composer's file list, at the daemon's own cap.
    static func listProjectFiles(cwd: String) -> WorkspaceOperation {
        .listProjectFiles(root: cwd, cap: 50_000)
    }
}

extension ProviderKind {
    /// Providers a user can pick, in the order the desktop lists them.
    /// `unknown` is a decoding fallback, never a choice.
    public static let selectable: [ProviderKind] = [
        .claude, .codex, .cursor, .amp, .openCode, .grok, .kimi, .deepSeek, .fx, .pi, .ohMyPi,
    ]
}
