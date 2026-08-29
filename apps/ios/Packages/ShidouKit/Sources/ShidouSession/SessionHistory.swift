import Foundation
import ShidouProtocol

/// Rewriting a session's history rather than extending it: forking a new task
/// from an answer, and rewinding to a prompt to send it again.
///
/// Both are daemon operations — it restores the workspace checkpoint, rebuilds
/// the transcript and hands back a whole session — so the phone's job is to
/// ask, adopt what comes back, and forget everything the old history implied.
extension SessionStore {
    /// What a fork produced: the new task, and the workspace's complaint if
    /// its checkpoint could not be restored cleanly.
    public struct ForkedSession: Sendable {
        public var session: AgentSession
        public var checkpointWarning: String?
    }

    // MARK: - Turn refs

    /// Which of this session's turns can still be rewound to. Empty until the
    /// background pass lands, which reads as "no rewind yet" rather than a
    /// promise the workspace cannot keep.
    public func retainedTurnCounts(for sessionId: UUID) -> Set<Int> {
        turnRefs[sessionId] ?? []
    }

    /// Resolve the whole session's checkpoint refs in one pass.
    ///
    /// A row builder must never ask "does this turn have a ref": that is a
    /// `git` invocation per prompt on every frame. One request answers for the
    /// session, and the transcript reads the answer out of the store.
    public func refreshTurnRefs(for session: AgentSession, force: Bool = false) {
        guard session.hasStarted, let cwd = cwd(for: session) else { return }
        if !force && turnRefs[session.id] != nil { return }
        guard turnRefLoads.insert(session.id).inserted else { return }
        let sessionId = session.id
        Task { [weak self] in
            guard let self else { return }
            defer { self.turnRefLoads.remove(sessionId) }
            guard case .workspace(.turnRefs(let counts))? = try? await self.request(
                .workspace(.sessionTurnRefs(cwd: cwd, sessionId: sessionId))
            ) else { return }
            self.turnRefs[sessionId] = Set(counts)
        }
    }

    // MARK: - Fork

    /// Starts a new task from an answer, keeping `turnCount` turns.
    ///
    /// The daemon does the work; what comes back is a whole session, which
    /// goes into the catalog and gets a projection of its own so the caller
    /// can open it straight away.
    @discardableResult
    public func forkFromResponse(
        _ model: SessionRuntimeModel,
        turnCount: Int
    ) async throws -> ForkedSession {
        let session = model.currentProjection
        guard forking.insert(session.id).inserted else {
            throw ShidouSessionError.alreadyRewritingHistory
        }
        defer { forking.remove(session.id) }
        let response = try await request(
            .forkSessionFromResponse(turnCount: turnCount),
            sessionId: session.id,
            runtimeId: model.runtimeId ?? .zero
        )
        guard case .sessionForked(let forked, let warning) = response else {
            throw ShidouSessionError.unexpectedResponse(expected: "sessionForked")
        }
        applyLocally(forked)
        adopt(forked)
        refreshCatalog()
        return ForkedSession(session: forked, checkpointWarning: warning)
    }

    // MARK: - Rewind

    /// Rewinds to a prompt and sends it again, edited or not.
    ///
    /// The daemon restores the checkpoint taken before that turn and returns
    /// the trimmed session. The old runtime is dropped rather than reused: it
    /// is still holding the history that was just discarded, and the next
    /// prompt has to start from the cursor the rewind left behind.
    ///
    /// Returns the workspace's warning when stale refs could not be cleaned
    /// up — the rewind still happened, so this is worth saying and not worth
    /// failing over.
    @discardableResult
    public func rewindToMessage(
        _ model: SessionRuntimeModel,
        turnCount: Int,
        prompt: String,
        attachments: [MessageAttachment] = []
    ) async throws -> String? {
        let session = model.currentProjection
        guard rewinding[session.id] == nil, !forking.contains(session.id) else {
            throw ShidouSessionError.alreadyRewritingHistory
        }
        rewinding[session.id] = turnCount
        defer { rewinding.removeValue(forKey: session.id) }
        let response = try await request(
            .rewindSessionToMessage(turnCount: turnCount),
            sessionId: session.id,
            runtimeId: model.runtimeId ?? .zero
        )
        guard case .sessionRewound(let rewound, let warning) = response else {
            throw ShidouSessionError.unexpectedResponse(expected: "sessionRewound")
        }
        model.clearRuntime()
        model.replaceSession(rewound)
        applyLocally(rewound)
        // Every fact the old history implied is now wrong: which turns have
        // refs, and what the working tree looks like.
        turnRefs.removeValue(forKey: rewound.id)
        refreshTurnRefs(for: rewound, force: true)
        refreshWorkspace(for: rewound, force: true)
        try await send(prompt: prompt, attachments: attachments, to: model)
        return warning
    }
}
