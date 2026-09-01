import Foundation
import ShidouProtocol

// Byte-faithful port of `apps/web/src/lib/event-reducer.ts`. The daemon owns
// the persisted Projection; the clients keep faithful reducer ports for live
// rendering, or a refetch makes the transcript flap between two shapes.

public struct PendingPermission: Hashable, Sendable {
    public var requestId: String
    public var title: String
    public var detail: String
    public var options: [PermissionOption]
}

public struct PendingUserInput: Hashable, Sendable {
    public var requestId: String
    public var questions: [UserInputQuestion]
}

public struct RuntimeEventResult: Sendable {
    public var session: AgentSession
    /// `.some(nil)` means "clear the pending permission"; `nil` means no change.
    public var permission: PendingPermission??
    public var userInput: PendingUserInput??
    public var settled: Bool
    public var removeRuntime: Bool
    public var resolvedInteractionId: String?
    public var error: String?
}

/// Injectable time/id source so reducer tests are deterministic.
public struct ReducerClock: Sendable {
    public var nowSeconds: @Sendable () -> UInt64
    public var nowMillis: @Sendable () -> UInt64
    public var randomUUID: @Sendable () -> UUID

    public init(
        nowSeconds: @escaping @Sendable () -> UInt64,
        nowMillis: @escaping @Sendable () -> UInt64,
        randomUUID: @escaping @Sendable () -> UUID
    ) {
        self.nowSeconds = nowSeconds
        self.nowMillis = nowMillis
        self.randomUUID = randomUUID
    }

    public static let live = ReducerClock(
        nowSeconds: { UInt64(Date().timeIntervalSince1970) },
        nowMillis: { UInt64(Date().timeIntervalSince1970 * 1000) },
        randomUUID: { UUID() }
    )
}

/// Skip events the persisted projection has already incorporated. Port of
/// `runtimeEventAlreadyApplied` — this is what makes the daemon's
/// whole-journal replay on reconnect harmless.
public func runtimeEventAlreadyApplied(session: AgentSession, event: SequencedEvent) -> Bool {
    guard let cursor = session.runtimeEventCursor else { return false }
    return cursor.runtimeId == event.runtimeId
        && cursor.epoch == event.epoch
        && cursor.sequence >= event.sequence
}

public func reduceRuntimeEvent(
    _ current: AgentSession,
    _ wire: SequencedEvent,
    clock: ReducerClock = .live,
    processExitError: String? = nil
) -> RuntimeEventResult {
    var session = current
    let kind = wire.event.kind
    let payload = wire.event.payload
    var result = RuntimeEventResult(
        session: session, permission: nil, userInput: nil,
        settled: false, removeRuntime: false, resolvedInteractionId: nil, error: nil
    )

    session.runtimeEventCursor = RuntimeEventCursor(
        runtimeId: wire.runtimeId, epoch: wire.epoch, sequence: wire.sequence
    )

    switch kind {
    case "connected":
        session.providerCursor = payload.isNull ? nil : payload
        if payload["provider"]?.stringValue == "claude",
            let resumeAt = payload["resumeAt"]?.stringValue,
            let index = activeTurnIndex(session)
        {
            session.turns[index].providerResumeAt = resumeAt
        }
        if session.status == .connecting { session.status = .working }
    case "agentPresetSelected":
        session.agentPreset = payload.stringValue
    case "autoTitleUpdated":
        let trimmed = payload.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
        session.autoTitle = (trimmed?.isEmpty == false) ? trimmed : nil
    case "availableCommands":
        if let commands = try? payload.decode(as: [ReportedCommand].self) {
            session.availableCommands = commands
        }
    case "turnAccepted":
        guard let accepted = try? payload.decode(as: TurnAcceptedPayload.self) else { break }
        acceptTurn(&session, accepted)
    case "turnStarted":
        if let index = activeTurnIndex(session) {
            session.turns[index].providerTurnStarted = true
            session.status = .working
        }
    case "textDelta":
        if let delta = payload.stringValue, acceptsTurnOutput(session) {
            appendText(&session, delta: delta, clock: clock)
        }
    case "reasoningDelta":
        if let delta = payload.stringValue, acceptsTurnOutput(session) {
            appendReasoning(&session, delta: delta, clock: clock)
        }
    case "activity":
        guard acceptsTurnOutput(session), let title = payload["title"]?.stringValue else { break }
        let kindValue = payload["kind"]?.stringValue.flatMap(ActivityKind.init(rawValue:))
        upsertActivity(
            &session,
            ActivityItem(
                id: clock.randomUUID(),
                sourceId: payload["id"]?.stringValue,
                kind: (kindValue == nil || kindValue == .unknown) ? .tool : kindValue!,
                title: title,
                detail: payload["detail"]?.stringValue,
                complete: payload["complete"]?.boolValue == true
            )
        )
    case "richActivity":
        guard acceptsTurnOutput(session), payload.objectValue != nil else { break }
        // The daemon assigns activity ids; keep them so upsert matching works.
        if let incoming = try? payload.decode(as: ActivityItem.self) {
            upsertActivity(&session, incoming)
        }
    case "permission":
        guard acceptsTurnOutput(session), let requestId = payload["requestId"]?.stringValue else { break }
        let options = (try? (payload["options"] ?? .array([])).decode(as: [PermissionOption].self)) ?? []
        result.permission = .some(PendingPermission(
            requestId: requestId,
            title: payload["title"]?.stringValue ?? "Permission required",
            detail: payload["detail"]?.stringValue ?? "",
            options: options
        ))
        session.status = .waiting
    case "userInputRequested":
        guard acceptsTurnOutput(session), let requestId = payload["requestId"]?.stringValue else { break }
        let questions = (try? (payload["questions"] ?? .array([])).decode(as: [UserInputQuestion].self)) ?? []
        guard !questions.isEmpty else { break }
        result.userInput = .some(PendingUserInput(requestId: requestId, questions: questions))
        session.status = .waiting
    case "interactionResolved":
        result.resolvedInteractionId = payload["requestId"]?.stringValue
    case "usageUpdated":
        guard payload.objectValue != nil else { break }
        let previous = session.contextUsage ?? ContextUsage(tokens: 0, window: nil)
        session.contextUsage = ContextUsage(
            tokens: payload["contextTokens"]?.intValue.map(UInt64.init) ?? previous.tokens,
            window: payload["contextWindow"]?.intValue.map(UInt64.init) ?? previous.window
        )
    case "turnFinished":
        let success = payload["success"]?.boolValue == true
        result.settled = settleTurn(
            &session,
            status: success ? .completed : .failed,
            fallback: payload["summary"]?.stringValue,
            clock: clock
        )
        result.permission = .some(nil)
        result.userInput = .some(nil)
    case "error":
        guard let message = payload.stringValue else { break }
        result.error = message
        guard let index = activeTurnIndex(session), session.status != .working else { break }
        let turnId = session.turns[index].id
        let hasAssistant = session.messages.contains {
            $0.turnId == turnId && $0.role == .assistant
        }
        session.status = .failed
        if !hasAssistant {
            session.messages.append(Message(
                id: clock.randomUUID(),
                turnId: turnId,
                role: .assistant,
                content: message,
                createdAt: clock.nowSeconds()
            ))
        }
    case "processExited":
        result.settled = settleTurn(
            &session,
            status: .failed,
            fallback: processExitError ?? "The agent exited before responding.",
            clock: clock
        )
        result.permission = .some(nil)
        result.userInput = .some(nil)
        result.removeRuntime = true
    default:
        break
    }

    session.updatedAt = clock.nowSeconds()
    result.session = session
    return result
}

// MARK: - Helpers (mirror the web reducer's private functions)

private func appendText(_ session: inout AgentSession, delta: String, clock: ReducerClock) {
    guard !delta.isEmpty else { return }
    completeReasoning(&session)
    if let last = session.messages.indices.last,
        session.messages[last].role == .assistant,
        session.messages[last].streaming
    {
        session.messages[last].content += delta
    } else {
        session.messages.append(Message(
            id: clock.randomUUID(),
            turnId: activeTurnIndex(session).map { session.turns[$0].id },
            role: .assistant,
            content: delta,
            createdAt: clock.nowSeconds(),
            streaming: true
        ))
    }
}

private func appendReasoning(_ session: inout AgentSession, delta: String, clock: ReducerClock) {
    let hasReasoning = lastReasoningLocation(session) != nil
    if delta.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !hasReasoning { return }
    finishStreamingMessages(&session)
    if let location = lastReasoningLocation(session),
        !session.transcriptBlocks[location.block].activities[location.activity].complete
    {
        session.transcriptBlocks[location.block].activities[location.activity].reasoning?.content += delta
        session.transcriptBlocks[location.block].activities[location.activity].reasoning?.finishedAtMs =
            clock.nowMillis()
        return
    }
    let now = clock.nowMillis()
    pushActivity(
        &session,
        ActivityItem(
            id: clock.randomUUID(),
            kind: .reasoning,
            title: "Reasoning",
            complete: false,
            reasoning: ReasoningBlock(content: delta, startedAtMs: now, finishedAtMs: now)
        )
    )
}

private func upsertActivity(_ session: inout AgentSession, _ incoming: ActivityItem) {
    finishStreamingMessages(&session)
    completeReasoning(&session)
    for blockIndex in session.transcriptBlocks.indices.reversed() {
        let activities = session.transcriptBlocks[blockIndex].activities
        let match = activities.indices.reversed().first { index in
            if let sourceId = incoming.sourceId, !sourceId.isEmpty {
                return activities[index].sourceId == sourceId
            }
            return activities[index].title == incoming.title && !activities[index].complete
        }
        guard let match else { continue }
        var merged = incoming
        let existing = activities[match]
        merged.id = existing.id
        merged.detail = incoming.detail ?? existing.detail
        merged.arguments = incoming.arguments ?? existing.arguments
        merged.output = incoming.output ?? existing.output
        merged.imageUrls = incoming.imageUrls.isEmpty ? existing.imageUrls : incoming.imageUrls
        merged.fileChanges = incoming.fileChanges.isEmpty ? existing.fileChanges : incoming.fileChanges
        merged.displayTarget = incoming.displayTarget ?? existing.displayTarget
        merged.displayDescription = incoming.displayDescription ?? existing.displayDescription
        merged.reasoning = incoming.reasoning ?? existing.reasoning
        session.transcriptBlocks[blockIndex].activities[match] = merged
        return
    }
    pushActivity(&session, incoming)
}

private func pushActivity(_ session: inout AgentSession, _ activity: ActivityItem) {
    let afterMessage = session.messages.count
    let turnId = activeTurnIndex(session).map { session.turns[$0].id }
    if let last = session.transcriptBlocks.indices.last,
        session.transcriptBlocks[last].afterMessage == afterMessage,
        session.transcriptBlocks[last].turnId == turnId
    {
        session.transcriptBlocks[last].activities.append(activity)
        return
    }
    session.transcriptBlocks.append(
        TranscriptBlock(afterMessage: afterMessage, turnId: turnId, activities: [activity])
    )
}

private func settleTurn(
    _ session: inout AgentSession,
    status: TurnStatus,
    fallback: String?,
    clock: ReducerClock
) -> Bool {
    finishStreamingMessages(&session)
    completeActivities(&session)
    guard let index = activeTurnIndex(session) else { return false }
    let turnId = session.turns[index].id
    let hasAssistant = session.messages.contains {
        $0.turnId == turnId && $0.role == .assistant
    }
    if !hasAssistant {
        session.messages.append(Message(
            id: clock.randomUUID(),
            turnId: turnId,
            role: .assistant,
            content: fallback
                ?? (status == .completed
                    ? "The turn completed without a text response."
                    : "The turn stopped before a response."),
            createdAt: clock.nowSeconds()
        ))
    }
    session.turns[index].status = status
    let completedAt = clock.nowSeconds()
    session.turns[index].completedAt = completedAt
    session.lastReplyAt = completedAt
    session.status = status == .completed ? .idle : .failed
    return true
}

private func finishStreamingMessages(_ session: inout AgentSession) {
    for index in session.messages.indices where session.messages[index].role == .assistant {
        session.messages[index].streaming = false
    }
}

private func completeReasoning(_ session: inout AgentSession) {
    if let location = lastReasoningLocation(session) {
        session.transcriptBlocks[location.block].activities[location.activity].complete = true
    }
}

private func completeActivities(_ session: inout AgentSession) {
    for blockIndex in session.transcriptBlocks.indices {
        for activityIndex in session.transcriptBlocks[blockIndex].activities.indices {
            session.transcriptBlocks[blockIndex].activities[activityIndex].complete = true
        }
    }
}

/// The trailing activity of the trailing block, when it carries reasoning.
private func lastReasoningLocation(_ session: AgentSession) -> (block: Int, activity: Int)? {
    guard let blockIndex = session.transcriptBlocks.indices.last,
        let activityIndex = session.transcriptBlocks[blockIndex].activities.indices.last,
        session.transcriptBlocks[blockIndex].activities[activityIndex].reasoning != nil
    else { return nil }
    return (blockIndex, activityIndex)
}

private struct TurnAcceptedPayload: Decodable {
    var submissionId: UUID
    var turn: AgentTurn
    var messages: [Message]
}

/// Incorporate the daemon's canonical record of a submitted prompt. A local
/// running turn is the instant echo shown before the daemon answers, so adopt
/// the canonical identities in place and retain its presentation data.
private func acceptTurn(_ session: inout AgentSession, _ accepted: TurnAcceptedPayload) {
    let knownTurn = session.turns.contains { $0.id == accepted.turn.id }
    let provisionalIndex = knownTurn ? nil : session.turns.firstIndex {
        $0.id == accepted.submissionId && $0.status == .running
    }

    if let provisionalIndex {
        let provisionalTurnId = session.turns[provisionalIndex].id
        session.turns[provisionalIndex] = accepted.turn
        var availableMessageIndices = session.messages.indices.filter {
            session.messages[$0].turnId == provisionalTurnId
        }
        for message in accepted.messages {
            guard !session.messages.contains(where: { $0.id == message.id }) else { continue }
            if let position = availableMessageIndices.firstIndex(where: {
                session.messages[$0].role == message.role
            }) {
                let index = availableMessageIndices.remove(at: position)
                session.messages[index].id = message.id
                session.messages[index].turnId = accepted.turn.id
            } else {
                session.messages.append(message)
            }
        }
        for index in availableMessageIndices {
            session.messages[index].turnId = accepted.turn.id
        }
        for index in session.transcriptBlocks.indices
        where session.transcriptBlocks[index].turnId == provisionalTurnId {
            session.transcriptBlocks[index].turnId = accepted.turn.id
        }
    } else {
        for message in accepted.messages
        where !session.messages.contains(where: { $0.id == message.id }) {
            session.messages.append(message)
        }
        if !knownTurn { session.turns.append(accepted.turn) }
    }

    if accepted.turn.status == .running, !session.status.isBusy {
        session.status = .connecting
    }
    session.updatedAt = max(session.updatedAt, accepted.turn.startedAt)
}

private func activeTurnIndex(_ session: AgentSession) -> Int? {
    guard let index = session.turns.indices.last, session.turns[index].status == .running else {
        return nil
    }
    return index
}

private func acceptsTurnOutput(_ session: AgentSession) -> Bool {
    activeTurnIndex(session) != nil
        && (session.status == .connecting || session.status == .working || session.status == .waiting)
}
