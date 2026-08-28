import Foundation
import ShidouProtocol

// Pure local mutations ported from `apps/web/src/lib/daemon-api.ts` — the
// daemon merges whatever we persist, so these must match the web client's
// shapes exactly.

public func unixTime() -> UInt64 {
    UInt64(Date().timeIntervalSince1970)
}

/// Port of `promptTitle`: first 7 words, capped at 54 characters.
public func promptTitle(_ prompt: String) -> String? {
    let words = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        .split(separator: " ", omittingEmptySubsequences: true)
        .prefix(7)
    var title = words.joined(separator: " ")
    if title.isEmpty { return nil }
    if title.count > 54 {
        title = String(title.prefix(53)) + "…"
    }
    return title
}

public func displayTitle(_ session: AgentSession) -> String {
    let trimmed = session.title.trimmingCharacters(in: .whitespaces)
    if session.title != AgentSession.defaultTitle && !trimmed.isEmpty { return session.title }
    if let auto = session.autoTitle?.trimmingCharacters(in: .whitespaces), !auto.isEmpty {
        return session.autoTitle!
    }
    return "New Task"
}

public func sessionCwd(_ session: AgentSession, project: Project) -> String {
    session.workspace.worktreePath ?? project.path
}

/// Port of `createSession`: a draft task, persisted via `saveTaskState`.
public func newSession(projectId: UUID, provider: ProviderKind, isolated: Bool) -> AgentSession {
    let now = unixTime()
    return AgentSession(
        projectId: projectId,
        workspace: isolated ? .newWorktree(baseBranch: nil) : .local,
        provider: provider,
        createdAt: now,
        updatedAt: now
    )
}

/// Port of `createProject`: validates an absolute daemon-host path.
public func newProject(path: String) throws -> Project {
    let input = path.trimmingCharacters(in: .whitespacesAndNewlines)
    let isWindowsPath = input.range(of: #"^[a-zA-Z]:[\\/]"#, options: .regularExpression) != nil
    guard input.hasPrefix("/") || isWindowsPath else {
        throw ShidouSessionError.relativeProjectPath
    }
    var normalized = input
    while normalized.count > 1 && (normalized.hasSuffix("/") || normalized.hasSuffix("\\")) {
        normalized.removeLast()
    }
    let name = normalized.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last.map(String.init)
        ?? "Project"
    return Project(name: name, path: normalized, createdAt: unixTime())
}

/// Port of `beginTurn`: appends the user message and a running turn.
public func beginTurn(
    _ session: AgentSession,
    prompt: String,
    attachments: [MessageAttachment] = []
) -> AgentSession {
    var next = session
    let now = unixTime()
    let turnId = UUID()
    let visiblePrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
    let mentions = attachments.map { "@\($0.mention)" }.joined(separator: " ")
    let providerPrompt = [visiblePrompt, mentions].filter { !$0.isEmpty }.joined(separator: " ")
    if next.messages.isEmpty, next.title == AgentSession.defaultTitle, next.autoTitle == nil {
        next.autoTitle = promptTitle(
            visiblePrompt.isEmpty ? (attachments.first?.name ?? "") : visiblePrompt
        )
    }
    next.status = .connecting
    next.updatedAt = now
    next.lastReplyAt = now
    next.messages.append(Message(
        turnId: turnId,
        role: .user,
        content: providerPrompt,
        displayContent: attachments.isEmpty ? nil : visiblePrompt,
        attachments: attachments,
        createdAt: now
    ))
    next.turns.append(AgentTurn(
        id: turnId,
        turnCount: next.turns.count + 1,
        status: .running,
        startedAt: now
    ))
    return next
}

/// Port of `queueSubmission`: a follow-up typed while the agent is busy.
public func queueSubmission(
    _ session: AgentSession,
    displayContent: String,
    providerPrompt: String,
    attachments: [MessageAttachment]
) -> AgentSession {
    var next = session
    let now = unixTime()
    next.updatedAt = now
    next.queuedMessages.append(QueuedMessage(
        content: providerPrompt,
        displayContent: (!attachments.isEmpty || providerPrompt != displayContent)
            ? displayContent : nil,
        attachments: attachments,
        createdAt: now
    ))
    return next
}

public enum ShidouSessionError: Error, LocalizedError, Sendable {
    case relativeProjectPath
    case projectNotFound
    case providerNotInstalled(ProviderKind)
    case unexpectedResponse(expected: String)
    case daemonDisconnected
    case noLiveRuntime
    case attachmentTooLarge(String)
    case patchTooLarge
    case noProviderForCommitMessage

    public var errorDescription: String? {
        switch self {
        case .relativeProjectPath:
            return "Enter an absolute path on the daemon host"
        case .projectNotFound:
            return "The task's project no longer exists"
        case .providerNotInstalled(let provider):
            return "\(provider.displayName) is not installed on the daemon host"
        case .unexpectedResponse(let expected):
            return "The daemon returned an unexpected response (expected \(expected))"
        case .daemonDisconnected:
            return "The daemon is not connected"
        case .noLiveRuntime:
            return "This task has no running agent"
        case .attachmentTooLarge(let name):
            return "\(name) is too large to send to the daemon"
        case .patchTooLarge:
            return "This change is too large to show on the phone"
        case .noProviderForCommitMessage:
            return "No installed provider can write a commit message"
        }
    }
}
