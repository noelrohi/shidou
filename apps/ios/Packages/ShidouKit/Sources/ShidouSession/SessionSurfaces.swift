import Foundation
import ShidouProtocol

// The store's half of the read-only surfaces, background work and git. Same
// reason the composer's half lives on the store: a tree fetch, a stop request
// and a commit all outlive the sheet that started them, and the iPhone sheet
// and the iPad inspector are two presentations of one state.

extension SessionStore {
    // MARK: - Surfaces

    /// The surfaces for one workspace directory, created once and kept for the
    /// connection. Two sessions in the same worktree share it, which is also
    /// what stops the inspector from refetching a tree the sheet just loaded.
    public func surfaces(for cwd: String) -> WorkspaceSurfaces {
        if let existing = workspaceSurfaces[cwd] { return existing }
        let created = WorkspaceSurfaces(cwd: cwd) { [weak self] command in
            guard let self else { throw ShidouSessionError.daemonDisconnected }
            return try await self.request(command)
        }
        workspaceSurfaces[cwd] = created
        return created
    }

    public func surfaces(for session: AgentSession) -> WorkspaceSurfaces? {
        guard let cwd = cwd(for: session), !cwd.isEmpty else { return nil }
        return surfaces(for: cwd)
    }

    // MARK: - Background work

    /// Ask the daemon for an authoritative snapshot of what is still running.
    ///
    /// A phone needs this more than the desktop does: the ledger is rebuilt
    /// from events, replay skips the ones the persisted projection already
    /// counted, and the surface is usually opened long after the process
    /// started. Without a refresh the panel would be empty on exactly the
    /// visit that matters.
    ///
    /// It throws rather than firing and forgetting: a refresh that never
    /// landed leaves the panel showing an empty list, and an empty list is
    /// also what "nothing is running" looks like. The surface has to be able
    /// to tell those apart.
    public func refreshBackgroundWork(_ sessionId: UUID) async throws {
        guard let model = open[sessionId], let runtimeId = model.runtimeId else { return }
        _ = try await request(
            .refreshBackgroundWork, sessionId: sessionId, runtimeId: runtimeId)
    }

    /// Stop one piece of background work. The row goes to `stopping`
    /// immediately: the daemon's own `stopRequested` event says the same
    /// thing, and waiting for it would leave a tapped button looking inert.
    public func stopBackgroundWork(_ sessionId: UUID, item: BackgroundWorkItem) async throws {
        guard let model = open[sessionId], let runtimeId = model.runtimeId else {
            throw ShidouSessionError.noLiveRuntime
        }
        model.markBackgroundWorkStopping(item.key)
        do {
            _ = try await request(
                .stopBackgroundWork(key: item.key, controlId: item.controlId ?? ""),
                sessionId: sessionId,
                runtimeId: runtimeId
            )
        } catch {
            // The command never landed, so nothing is stopping. Put the row
            // back where it was rather than leaving it mid-stop forever.
            model.backgroundWorkStopFailed(item.key, message: error.localizedDescription)
            throw error
        }
    }

    // MARK: - Git

    /// Fresh commit state for one workspace. Unlike `refreshWorkspace` this
    /// awaits: the commit sheet is a one-shot user action, where being current
    /// matters more than latency.
    @discardableResult
    public func inspectCommit(cwd: String) async throws -> CommitSnapshot {
        guard case .workspace(.commitSnapshot(let snapshot)) = try await request(
            .workspace(.inspectCommit(cwd: cwd)))
        else {
            throw ShidouSessionError.unexpectedResponse(expected: "commitSnapshot")
        }
        setWorkspaceSnapshot(snapshot, for: cwd)
        return snapshot
    }

    /// Ask an installed provider to write the commit message.
    ///
    /// The daemon needs to be told which agent to run and where its binary is,
    /// so this resolves the session's own provider first and falls back to any
    /// installed one — a task started with a provider that has since been
    /// uninstalled should still be committable.
    public func generateCommitMessage(
        cwd: String,
        session: AgentSession,
        includeUnstaged: Bool
    ) async throws -> String {
        let settings = try await loadSettings()
        let invocation = try await commitMessageInvocation(for: session, settings: settings)
        guard case .workspace(.commitMessage(let message)) = try await request(
            .workspace(.generateCommitMessage(
                cwd: cwd,
                includeUnstaged: includeUnstaged,
                conventionalCommits: settings.conventionalCommitMessages,
                invocation: invocation
            )))
        else {
            throw ShidouSessionError.unexpectedResponse(expected: "commitMessage")
        }
        return message
    }

    private func commitMessageInvocation(
        for session: AgentSession, settings: DaemonSettings
    ) async throws -> AgentInvocation {
        var candidates = [session.provider]
        candidates += ProviderKind.selectable.filter {
            $0 != session.provider && settings.isEnabled($0)
        }
        for provider in candidates {
            guard let probe = try? await loadProbe(provider), probe.installed,
                let binary = probe.path
            else { continue }
            return AgentInvocation(
                provider: provider,
                binary: binary,
                model: provider == session.provider ? session.model : nil,
                reasoningEffort: provider == session.provider ? session.reasoningEffort : nil
            )
        }
        throw ShidouSessionError.noProviderForCommitMessage
    }

    /// Commit, optionally pushing in the same operation. The daemon does both
    /// under one lock, which is why `push` is a flag here rather than a second
    /// command the phone would have to sequence itself.
    @discardableResult
    public func commit(
        cwd: String, message: String, includeUnstaged: Bool, push: Bool
    ) async throws -> CommitSnapshot {
        _ = try await request(
            .workspace(.commit(
                cwd: cwd, message: message, includeUnstaged: includeUnstaged, push: push)))
        return try await inspectCommit(cwd: cwd)
    }

    @discardableResult
    public func push(cwd: String) async throws -> CommitSnapshot {
        _ = try await request(.workspace(.push(cwd: cwd)))
        return try await inspectCommit(cwd: cwd)
    }

    // MARK: - Settings

    /// Write settings back and keep the cached copy in step.
    ///
    /// `DaemonSettings` round-trips every key it decoded, so this cannot drop
    /// a desktop-only setting the phone has no screen for.
    public func updateSettings(_ settings: DaemonSettings) async throws {
        _ = try await request(.updateSettings(settings))
        self.settings = settings
        // A binary override or a disabled provider changes what a probe would
        // answer, so the cached probes are no longer about these settings.
        probes.removeAll()
    }

    /// Re-read settings from the daemon, past the connection cache — the
    /// settings screen is where another client's change has to show up.
    @discardableResult
    public func reloadSettings() async throws -> DaemonSettings {
        settings = nil
        return try await loadSettings()
    }

    // MARK: - Skills

    public func loadSkills() async throws -> SkillsCatalog {
        let roots = projects.map { SkillProjectRoot(name: $0.name, root: $0.path) }
        guard case .skillsCatalog(let catalog) = try await request(.loadSkills(projects: roots))
        else {
            throw ShidouSessionError.unexpectedResponse(expected: "skillsCatalog")
        }
        return catalog
    }

    public func setSkillsEnabled(dirs: [String], enabled: Bool) async throws {
        _ = try await request(.setSkillsEnabled(dirs: dirs, enabled: enabled))
    }

    public func trashSkills(dirs: [String]) async throws {
        _ = try await request(.trashSkills(dirs: dirs))
    }

    // MARK: - Usage

    public func loadUsageHistory(window: UsageWindow) async throws -> UsageHistory {
        guard case .usageHistory(let history) = try await request(
            .loadUsageHistory(window: window, projectRoots: projects.map(\.path)))
        else {
            throw ShidouSessionError.unexpectedResponse(expected: "usageHistory")
        }
        return history
    }
}
