import Foundation

// Mirrors `crates/shidou-protocol/src/model.rs`. These model types have no
// serde `rename_all`, so their wire fields are snake_case; string enums are
// camelCase values. Every string enum keeps an `unknown` fallback so a newer
// daemon cannot break decoding.

/// A string-backed protocol enum that tolerates values this build doesn't know.
public protocol WireStringEnum: Codable, Hashable, Sendable, RawRepresentable
where RawValue == String {
    static var unknownCase: Self { get }
    init?(rawValue: String)
}

extension WireStringEnum {
    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = Self(rawValue: raw) ?? Self.unknownCase
    }
}

public enum ProviderKind: String, WireStringEnum {
    case amp, claude, codex, cursor, deepSeek, fx, openCode, grok, kimi, ohMyPi, pi
    case unknown

    public static var unknownCase: Self { .unknown }

    public var displayName: String {
        switch self {
        case .amp: return "Amp"
        case .claude: return "Claude Code"
        case .codex: return "Codex CLI"
        case .cursor: return "Cursor CLI"
        case .deepSeek: return "DeepSeek Harness"
        case .fx: return "Fx"
        case .openCode: return "OpenCode"
        case .grok: return "Grok Build"
        case .kimi: return "Kimi Code"
        case .ohMyPi: return "Oh My Pi"
        case .pi: return "Pi"
        case .unknown: return "Unknown"
        }
    }
}

public enum RuntimeMode: String, WireStringEnum {
    case plan, ask, autoAcceptEdits, auto, fullAccess
    case unknown

    public static var unknownCase: Self { .unknown }
}

public enum InteractionMode: String, WireStringEnum {
    case build, plan
    case unknown

    public static var unknownCase: Self { .unknown }
}

public enum SessionStatus: String, WireStringEnum {
    case idle, connecting, working, waiting, failed
    case unknown

    public static var unknownCase: Self { .unknown }

    public var isBusy: Bool {
        self == .connecting || self == .working || self == .waiting
    }
}

public enum TurnStatus: String, WireStringEnum {
    case running, completed, failed, interrupted
    case unknown

    public static var unknownCase: Self { .unknown }
}

public enum CheckpointStatus: String, WireStringEnum {
    case ready, unavailable, error
    case unknown

    public static var unknownCase: Self { .unknown }
}

public enum MessageRole: String, WireStringEnum {
    case user, assistant, system
    case unknown

    public static var unknownCase: Self { .unknown }
}

public enum ActivityKind: String, WireStringEnum {
    case reasoning, command, fileChange, fileRead, fileSearch, fileList, search, plan, tool
    case unknown

    public static var unknownCase: Self { .unknown }
}

public enum ActivityFileChangeStatus: String, WireStringEnum {
    case added, modified, deleted
    case unknown

    public static var unknownCase: Self { .unknown }
}

/// Filesystem context a project preselects for its new tasks.
public enum ProjectWorkspaceDefault: String, WireStringEnum {
    case local = "Local"
    case newWorktree = "NewWorktree"
    case unknown = "Unknown"

    public static var unknownCase: Self { .unknown }

    /// Mirrors `ProjectWorkspaceDefault::session_workspace`.
    public var sessionWorkspace: SessionWorkspace {
        self == .newWorktree ? .newWorktree(baseBranch: nil) : .local
    }
}

public struct Project: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var path: String
    public var createdAt: UInt64
    public var workspaceDefault: ProjectWorkspaceDefault

    enum CodingKeys: String, CodingKey {
        case id, name, path
        case createdAt = "created_at"
        case workspaceDefault = "workspace_default"
    }

    public init(
        id: UUID = UUID(),
        name: String,
        path: String,
        createdAt: UInt64,
        workspaceDefault: ProjectWorkspaceDefault = .local
    ) {
        self.id = id
        self.name = name
        self.path = path
        self.createdAt = createdAt
        self.workspaceDefault = workspaceDefault
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        path = try container.decode(String.self, forKey: .path)
        createdAt = try container.decodeIfPresent(UInt64.self, forKey: .createdAt) ?? 0
        workspaceDefault =
            try container.decodeIfPresent(ProjectWorkspaceDefault.self, forKey: .workspaceDefault)
            ?? .local
    }

    public static let projectlessName = "No project"

    /// The daemon's scratch workspace, kept out of the project picker's list
    /// and offered as its own choice instead.
    public var isProjectless: Bool { name == Self.projectlessName }
}

/// Filesystem context a task runs in. Tagged by `kind`, camelCase fields.
public enum SessionWorkspace: Codable, Hashable, Sendable {
    case local
    case newWorktree(baseBranch: String?)
    case worktree(path: String, branch: String)
    case unknown(kind: String)

    enum CodingKeys: String, CodingKey {
        case kind, baseBranch, path, branch
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(String.self, forKey: .kind)
        switch kind {
        case "local":
            self = .local
        case "newWorktree":
            self = .newWorktree(baseBranch: try container.decodeIfPresent(String.self, forKey: .baseBranch))
        case "worktree":
            self = .worktree(
                path: try container.decode(String.self, forKey: .path),
                branch: try container.decode(String.self, forKey: .branch)
            )
        default:
            self = .unknown(kind: kind)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .local:
            try container.encode("local", forKey: .kind)
        case .newWorktree(let baseBranch):
            try container.encode("newWorktree", forKey: .kind)
            try container.encodeIfPresent(baseBranch, forKey: .baseBranch)
        case .worktree(let path, let branch):
            try container.encode("worktree", forKey: .kind)
            try container.encode(path, forKey: .path)
            try container.encode(branch, forKey: .branch)
        case .unknown(let kind):
            try container.encode(kind, forKey: .kind)
        }
    }

    public var isLocal: Bool {
        if case .local = self { return true }
        return false
    }

    public var worktreePath: String? {
        if case .worktree(let path, _) = self { return path }
        return nil
    }
}

public struct MessageAttachment: Codable, Hashable, Sendable {
    /// Absolute path on the daemon host. Clients must use `blobReference`
    /// rather than opening this path themselves.
    public var path: String
    public var mention: String
    public var name: String
    public var isDir: Bool
    public var isImage: Bool
    public var blobReference: String?

    enum CodingKeys: String, CodingKey {
        case path, mention, name
        case isDir = "is_dir"
        case isImage = "is_image"
        case blobReference = "blob_reference"
    }

    public init(
        path: String,
        mention: String,
        name: String,
        isDir: Bool,
        isImage: Bool,
        blobReference: String? = nil
    ) {
        self.path = path
        self.mention = mention
        self.name = name
        self.isDir = isDir
        self.isImage = isImage
        self.blobReference = blobReference
    }
}

public struct Message: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var turnId: UUID?
    public var role: MessageRole
    public var content: String
    /// User-visible text before provider-facing attachment mentions were
    /// appended. Plain and legacy messages omit it.
    public var displayContent: String?
    public var attachments: [MessageAttachment]
    public var createdAt: UInt64
    public var streaming: Bool

    enum CodingKeys: String, CodingKey {
        case id, role, content, attachments, streaming
        case turnId = "turn_id"
        case displayContent = "display_content"
        case createdAt = "created_at"
    }

    public init(
        id: UUID = UUID(),
        turnId: UUID? = nil,
        role: MessageRole,
        content: String,
        displayContent: String? = nil,
        attachments: [MessageAttachment] = [],
        createdAt: UInt64,
        streaming: Bool = false
    ) {
        self.id = id
        self.turnId = turnId
        self.role = role
        self.content = content
        self.displayContent = displayContent
        self.attachments = attachments
        self.createdAt = createdAt
        self.streaming = streaming
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        turnId = try container.decodeIfPresent(UUID.self, forKey: .turnId)
        role = try container.decode(MessageRole.self, forKey: .role)
        content = try container.decode(String.self, forKey: .content)
        displayContent = try container.decodeIfPresent(String.self, forKey: .displayContent)
        attachments = try container.decodeIfPresent([MessageAttachment].self, forKey: .attachments) ?? []
        createdAt = try container.decode(UInt64.self, forKey: .createdAt)
        streaming = try container.decode(Bool.self, forKey: .streaming)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id.wireString, forKey: .id)
        try container.encodeIfPresent(turnId?.wireString, forKey: .turnId)
        try container.encode(role, forKey: .role)
        try container.encode(content, forKey: .content)
        try container.encodeIfPresent(displayContent, forKey: .displayContent)
        if !attachments.isEmpty {
            try container.encode(attachments, forKey: .attachments)
        }
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(streaming, forKey: .streaming)
    }

    public var visibleContent: String {
        displayContent ?? content
    }
}

public struct ReasoningBlock: Codable, Hashable, Sendable {
    public var content: String
    public var startedAtMs: UInt64
    public var finishedAtMs: UInt64

    enum CodingKeys: String, CodingKey {
        case content
        case startedAtMs = "started_at_ms"
        case finishedAtMs = "finished_at_ms"
    }

    public init(content: String, startedAtMs: UInt64, finishedAtMs: UInt64) {
        self.content = content
        self.startedAtMs = startedAtMs
        self.finishedAtMs = finishedAtMs
    }
}

public struct ActivityFileChange: Codable, Hashable, Sendable {
    public var path: String
    public var additions: UInt64?
    public var deletions: UInt64?
    public var status: ActivityFileChangeStatus?
    /// Unified-diff body normalized once by the daemon; render from this.
    public var diff: String?
}

public struct ActivityItem: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var sourceId: String?
    public var kind: ActivityKind
    public var title: String
    public var detail: String?
    public var arguments: String?
    public var output: String?
    public var imageUrls: [String]
    public var failed: Bool
    public var complete: Bool
    public var fileChanges: [ActivityFileChange]
    public var displayTarget: String?
    public var displayDescription: String?
    /// Native model reasoning carried in the ordered activity stream.
    public var reasoning: ReasoningBlock?

    enum CodingKeys: String, CodingKey {
        case id, kind, title, detail, arguments, output, failed, complete, reasoning
        case sourceId = "source_id"
        case imageUrls = "image_urls"
        case fileChanges = "file_changes"
        case displayTarget = "display_target"
        case displayDescription = "display_description"
    }

    public init(
        id: UUID = UUID(),
        sourceId: String? = nil,
        kind: ActivityKind,
        title: String,
        detail: String? = nil,
        arguments: String? = nil,
        output: String? = nil,
        imageUrls: [String] = [],
        failed: Bool = false,
        complete: Bool,
        fileChanges: [ActivityFileChange] = [],
        displayTarget: String? = nil,
        displayDescription: String? = nil,
        reasoning: ReasoningBlock? = nil
    ) {
        self.id = id
        self.sourceId = sourceId
        self.kind = kind
        self.title = title
        self.detail = detail
        self.arguments = arguments
        self.output = output
        self.imageUrls = imageUrls
        self.failed = failed
        self.complete = complete
        self.fileChanges = fileChanges
        self.displayTarget = displayTarget
        self.displayDescription = displayDescription
        self.reasoning = reasoning
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        sourceId = try container.decodeIfPresent(String.self, forKey: .sourceId)
        kind = try container.decode(ActivityKind.self, forKey: .kind)
        title = try container.decode(String.self, forKey: .title)
        detail = try container.decodeIfPresent(String.self, forKey: .detail)
        arguments = try container.decodeIfPresent(String.self, forKey: .arguments)
        output = try container.decodeIfPresent(String.self, forKey: .output)
        imageUrls = try container.decodeIfPresent([String].self, forKey: .imageUrls) ?? []
        failed = try container.decodeIfPresent(Bool.self, forKey: .failed) ?? false
        complete = try container.decode(Bool.self, forKey: .complete)
        fileChanges = try container.decodeIfPresent([ActivityFileChange].self, forKey: .fileChanges) ?? []
        displayTarget = try container.decodeIfPresent(String.self, forKey: .displayTarget)
        displayDescription = try container.decodeIfPresent(String.self, forKey: .displayDescription)
        reasoning = try container.decodeIfPresent(ReasoningBlock.self, forKey: .reasoning)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id.wireString, forKey: .id)
        try container.encode(sourceId, forKey: .sourceId)
        try container.encode(kind, forKey: .kind)
        try container.encode(title, forKey: .title)
        try container.encode(detail, forKey: .detail)
        try container.encodeIfPresent(arguments, forKey: .arguments)
        try container.encodeIfPresent(output, forKey: .output)
        if !imageUrls.isEmpty { try container.encode(imageUrls, forKey: .imageUrls) }
        try container.encode(failed, forKey: .failed)
        try container.encode(complete, forKey: .complete)
        if !fileChanges.isEmpty { try container.encode(fileChanges, forKey: .fileChanges) }
        try container.encodeIfPresent(displayTarget, forKey: .displayTarget)
        try container.encodeIfPresent(displayDescription, forKey: .displayDescription)
        try container.encodeIfPresent(reasoning, forKey: .reasoning)
    }

    public static func fromReasoning(_ reasoning: ReasoningBlock, complete: Bool) -> Self {
        Self(kind: .reasoning, title: "Reasoning", complete: complete, reasoning: reasoning)
    }
}

/// Persisted as `{"after_message":n,"turn_id":…,"content":{"kind":"activities","data":[…]}}`.
/// The legacy `{"kind":"reasoning","data":…}` shape must still decode.
public struct TranscriptBlock: Codable, Hashable, Sendable {
    public var afterMessage: Int
    public var turnId: UUID?
    public var activities: [ActivityItem]

    enum CodingKeys: String, CodingKey {
        case afterMessage = "after_message"
        case turnId = "turn_id"
        case content
    }

    enum ContentKeys: String, CodingKey {
        case kind, data
    }

    public init(afterMessage: Int, turnId: UUID?, activities: [ActivityItem]) {
        self.afterMessage = afterMessage
        self.turnId = turnId
        self.activities = activities
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        afterMessage = try container.decode(Int.self, forKey: .afterMessage)
        turnId = try container.decodeIfPresent(UUID.self, forKey: .turnId)
        let content = try container.nestedContainer(keyedBy: ContentKeys.self, forKey: .content)
        let kind = try content.decode(String.self, forKey: .kind)
        switch kind {
        case "activities":
            activities = try content.decode([ActivityItem].self, forKey: .data)
        case "reasoning":
            let reasoning = try content.decode(ReasoningBlock.self, forKey: .data)
            activities = [.fromReasoning(reasoning, complete: true)]
        default:
            activities = []
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(afterMessage, forKey: .afterMessage)
        try container.encode(turnId?.wireString, forKey: .turnId)
        var content = container.nestedContainer(keyedBy: ContentKeys.self, forKey: .content)
        try content.encode("activities", forKey: .kind)
        try content.encode(activities, forKey: .data)
    }
}

public struct CheckpointFile: Codable, Hashable, Sendable {
    public var path: String
    public var additions: UInt64
    public var deletions: UInt64
}

public struct Checkpoint: Codable, Hashable, Sendable {
    public var turnCount: Int
    public var gitRef: String
    public var status: CheckpointStatus
    public var files: [CheckpointFile]
    public var additions: UInt64
    public var deletions: UInt64
    public var createdAt: UInt64

    enum CodingKeys: String, CodingKey {
        case status, files, additions, deletions
        case turnCount = "turn_count"
        case gitRef = "git_ref"
        case createdAt = "created_at"
    }

    public init(
        turnCount: Int,
        gitRef: String,
        status: CheckpointStatus,
        files: [CheckpointFile] = [],
        additions: UInt64 = 0,
        deletions: UInt64 = 0,
        createdAt: UInt64
    ) {
        self.turnCount = turnCount
        self.gitRef = gitRef
        self.status = status
        self.files = files
        self.additions = additions
        self.deletions = deletions
        self.createdAt = createdAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        turnCount = try container.decode(Int.self, forKey: .turnCount)
        gitRef = try container.decode(String.self, forKey: .gitRef)
        status = try container.decode(CheckpointStatus.self, forKey: .status)
        files = try container.decodeIfPresent([CheckpointFile].self, forKey: .files) ?? []
        additions = try container.decodeIfPresent(UInt64.self, forKey: .additions) ?? 0
        deletions = try container.decodeIfPresent(UInt64.self, forKey: .deletions) ?? 0
        createdAt = try container.decode(UInt64.self, forKey: .createdAt)
    }
}

public struct AgentTurn: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var turnCount: Int
    public var status: TurnStatus
    public var providerTurnStarted: Bool
    public var providerResumeAt: String?
    public var startedAt: UInt64
    public var completedAt: UInt64?
    public var checkpoint: Checkpoint?

    enum CodingKeys: String, CodingKey {
        case id, status, checkpoint
        case turnCount = "turn_count"
        case providerTurnStarted = "provider_turn_started"
        case providerResumeAt = "provider_resume_at"
        case startedAt = "started_at"
        case completedAt = "completed_at"
    }

    public init(
        id: UUID = UUID(),
        turnCount: Int,
        status: TurnStatus,
        providerTurnStarted: Bool = false,
        providerResumeAt: String? = nil,
        startedAt: UInt64,
        completedAt: UInt64? = nil,
        checkpoint: Checkpoint? = nil
    ) {
        self.id = id
        self.turnCount = turnCount
        self.status = status
        self.providerTurnStarted = providerTurnStarted
        self.providerResumeAt = providerResumeAt
        self.startedAt = startedAt
        self.completedAt = completedAt
        self.checkpoint = checkpoint
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        turnCount = try container.decode(Int.self, forKey: .turnCount)
        status = try container.decode(TurnStatus.self, forKey: .status)
        providerTurnStarted = try container.decodeIfPresent(Bool.self, forKey: .providerTurnStarted) ?? false
        providerResumeAt = try container.decodeIfPresent(String.self, forKey: .providerResumeAt)
        startedAt = try container.decode(UInt64.self, forKey: .startedAt)
        completedAt = try container.decodeIfPresent(UInt64.self, forKey: .completedAt)
        checkpoint = try container.decodeIfPresent(Checkpoint.self, forKey: .checkpoint)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id.wireString, forKey: .id)
        try container.encode(turnCount, forKey: .turnCount)
        try container.encode(status, forKey: .status)
        try container.encode(providerTurnStarted, forKey: .providerTurnStarted)
        try container.encodeIfPresent(providerResumeAt, forKey: .providerResumeAt)
        try container.encode(startedAt, forKey: .startedAt)
        try container.encode(completedAt, forKey: .completedAt)
        try container.encodeIfPresent(checkpoint, forKey: .checkpoint)
    }
}

public struct ContextUsage: Codable, Hashable, Sendable {
    public var tokens: UInt64
    public var window: UInt64?

    public init(tokens: UInt64, window: UInt64? = nil) {
        self.tokens = tokens
        self.window = window
    }
}

/// Last daemon event incorporated into a session's persisted projection.
public struct RuntimeEventCursor: Codable, Hashable, Sendable {
    public var runtimeId: UUID
    public var epoch: UUID
    public var sequence: UInt64

    enum CodingKeys: String, CodingKey {
        case epoch, sequence
        case runtimeId = "runtime_id"
    }

    public init(runtimeId: UUID, epoch: UUID, sequence: UInt64) {
        self.runtimeId = runtimeId
        self.epoch = epoch
        self.sequence = sequence
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(runtimeId.wireString, forKey: .runtimeId)
        try container.encode(epoch.wireString, forKey: .epoch)
        try container.encode(sequence, forKey: .sequence)
    }
}

public struct QueuedMessage: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var content: String
    public var displayContent: String?
    public var attachments: [MessageAttachment]
    public var createdAt: UInt64

    enum CodingKeys: String, CodingKey {
        case id, content, attachments
        case displayContent = "display_content"
        case createdAt = "created_at"
    }

    public init(
        id: UUID = UUID(),
        content: String,
        displayContent: String? = nil,
        attachments: [MessageAttachment] = [],
        createdAt: UInt64
    ) {
        self.id = id
        self.content = content
        self.displayContent = displayContent
        self.attachments = attachments
        self.createdAt = createdAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        content = try container.decode(String.self, forKey: .content)
        displayContent = try container.decodeIfPresent(String.self, forKey: .displayContent)
        attachments = try container.decodeIfPresent([MessageAttachment].self, forKey: .attachments) ?? []
        createdAt = try container.decode(UInt64.self, forKey: .createdAt)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id.wireString, forKey: .id)
        try container.encode(content, forKey: .content)
        try container.encodeIfPresent(displayContent, forKey: .displayContent)
        if !attachments.isEmpty { try container.encode(attachments, forKey: .attachments) }
        try container.encode(createdAt, forKey: .createdAt)
    }

    public var visibleContent: String {
        displayContent ?? content
    }
}

/// A slash command a live provider process advertised. Older builds persisted
/// bare strings, which the untagged repr still accepts.
public struct ReportedCommand: Codable, Hashable, Sendable {
    public var name: String
    public var description: String

    public init(name: String, description: String = "") {
        self.name = name
        self.description = description
    }

    public init(from decoder: Decoder) throws {
        if let container = try? decoder.singleValueContainer(),
            let name = try? container.decode(String.self)
        {
            self.name = name
            self.description = ""
            return
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        description = try container.decodeIfPresent(String.self, forKey: .description) ?? ""
    }

    enum CodingKeys: String, CodingKey {
        case name, description
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name, forKey: .name)
        if !description.isEmpty {
            try container.encode(description, forKey: .description)
        }
    }
}

public struct PermissionOption: Codable, Hashable, Sendable {
    public var id: String
    public var label: String
    public var allow: Bool
}

public struct UserInputOption: Codable, Hashable, Sendable {
    public var label: String
    public var description: String?
}

public struct UserInputQuestion: Codable, Hashable, Sendable {
    public var id: String
    public var header: String
    public var question: String
    public var options: [UserInputOption]
    public var multiSelect: Bool

    enum CodingKeys: String, CodingKey {
        case id, header, question, options, multiSelect
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        header = try container.decode(String.self, forKey: .header)
        question = try container.decode(String.self, forKey: .question)
        options = try container.decodeIfPresent([UserInputOption].self, forKey: .options) ?? []
        multiSelect = try container.decodeIfPresent(Bool.self, forKey: .multiSelect) ?? false
    }
}

public struct UserInputAnswer: Codable, Hashable, Sendable {
    public var questionId: String
    public var answers: [String]

    enum CodingKeys: String, CodingKey {
        case questionId, answers
    }

    public init(questionId: String, answers: [String]) {
        self.questionId = questionId
        self.answers = answers
    }
}

public struct ProviderModelOption: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var label: String
    public var description: String?

    public init(id: String, label: String, description: String? = nil) {
        self.id = id
        self.label = label
        self.description = description
    }
}

public struct ProviderModel: Codable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var subProvider: String?
    public var isDefault: Bool
    public var reasoningEfforts: [ProviderModelOption]
    public var defaultReasoningEffort: String?
    public var serviceTiers: [ProviderModelOption]
    public var defaultServiceTier: String?
    public var contextWindows: [ProviderModelOption]
    public var defaultContextWindow: String?

    enum CodingKeys: String, CodingKey {
        case id, name
        case subProvider = "sub_provider"
        case isDefault = "is_default"
        case reasoningEfforts = "reasoning_efforts"
        case defaultReasoningEffort = "default_reasoning_effort"
        case serviceTiers = "service_tiers"
        case defaultServiceTier = "default_service_tier"
        case contextWindows = "context_windows"
        case defaultContextWindow = "default_context_window"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        subProvider = try container.decodeIfPresent(String.self, forKey: .subProvider)
        isDefault = try container.decodeIfPresent(Bool.self, forKey: .isDefault) ?? false
        reasoningEfforts = try container.decodeIfPresent([ProviderModelOption].self, forKey: .reasoningEfforts) ?? []
        defaultReasoningEffort = try container.decodeIfPresent(String.self, forKey: .defaultReasoningEffort)
        serviceTiers = try container.decodeIfPresent([ProviderModelOption].self, forKey: .serviceTiers) ?? []
        defaultServiceTier = try container.decodeIfPresent(String.self, forKey: .defaultServiceTier)
        contextWindows = try container.decodeIfPresent([ProviderModelOption].self, forKey: .contextWindows) ?? []
        defaultContextWindow = try container.decodeIfPresent(String.self, forKey: .defaultContextWindow)
    }
}

public struct ProviderAgentPreset: Codable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var description: String?
    public var isDefault: Bool
    public var isCustom: Bool

    enum CodingKeys: String, CodingKey {
        case id, name, description
        case isDefault = "is_default"
        case isCustom = "is_custom"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        description = try container.decodeIfPresent(String.self, forKey: .description)
        isDefault = try container.decodeIfPresent(Bool.self, forKey: .isDefault) ?? false
        isCustom = try container.decodeIfPresent(Bool.self, forKey: .isCustom) ?? false
    }
}

public struct ProviderProbe: Codable, Sendable {
    public var provider: ProviderKind
    public var installed: Bool
    public var path: String?
    public var models: [ProviderModel]
    public var agentPresets: [ProviderAgentPreset]

    enum CodingKeys: String, CodingKey {
        case provider, installed, path, models
        case agentPresets = "agent_presets"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        provider = try container.decode(ProviderKind.self, forKey: .provider)
        installed = try container.decode(Bool.self, forKey: .installed)
        path = try container.decodeIfPresent(String.self, forKey: .path)
        models = try container.decodeIfPresent([ProviderModel].self, forKey: .models) ?? []
        agentPresets = try container.decodeIfPresent([ProviderAgentPreset].self, forKey: .agentPresets) ?? []
    }

    public var preferredModel: ProviderModel? {
        models.first(where: \.isDefault) ?? models.first
    }
}

/// Daemon settings; iOS only reads the fields it needs and never writes
/// settings back, so unknown fields are simply ignored on decode.
public struct DaemonSettings: Codable, Sendable {
    public var computerUseEnabled: Bool
    public var conventionalCommitMessages: Bool
    public var disabledProviders: [ProviderKind]
    public var providerBinaryOverrides: [String: String]

    enum CodingKeys: String, CodingKey {
        case computerUseEnabled = "computer_use_enabled"
        case conventionalCommitMessages = "conventional_commit_messages"
        case disabledProviders = "disabled_providers"
        case providerBinaryOverrides = "provider_binary_overrides"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        computerUseEnabled = try container.decodeIfPresent(Bool.self, forKey: .computerUseEnabled) ?? false
        conventionalCommitMessages =
            try container.decodeIfPresent(Bool.self, forKey: .conventionalCommitMessages) ?? false
        disabledProviders = try container.decodeIfPresent([ProviderKind].self, forKey: .disabledProviders) ?? []
        providerBinaryOverrides =
            try container.decodeIfPresent([String: String].self, forKey: .providerBinaryOverrides) ?? [:]
    }

    public func binaryOverride(for provider: ProviderKind) -> String? {
        providerBinaryOverrides[provider.rawValue]
    }
}

public struct AgentSession: Codable, Identifiable, Sendable {
    public var id: UUID
    public var title: String
    public var autoTitle: String?
    public var projectId: UUID
    public var workspace: SessionWorkspace
    public var provider: ProviderKind
    public var model: String?
    public var runtimeMode: RuntimeMode
    public var interactionMode: InteractionMode
    public var reasoningEffort: String?
    public var serviceTier: String?
    public var contextWindow: String?
    public var agentPreset: String?
    public var status: SessionStatus
    public var createdAt: UInt64
    public var updatedAt: UInt64
    public var lastReplyAt: UInt64?
    /// Provider-specific resume state; only round-tripped, never interpreted.
    public var providerCursor: JSONValue?
    public var availableCommands: [ReportedCommand]
    public var contextUsage: ContextUsage?
    public var runtimeEventCursor: RuntimeEventCursor?
    public var messages: [Message]
    public var transcriptBlocks: [TranscriptBlock]
    public var turns: [AgentTurn]
    public var queuedMessages: [QueuedMessage]

    public static let defaultTitle = "New task"

    enum CodingKeys: String, CodingKey {
        case id, title, workspace, provider, model, status, messages, turns
        case autoTitle = "auto_title"
        case projectId = "project_id"
        case runtimeMode = "runtime_mode"
        case interactionMode = "interaction_mode"
        case reasoningEffort = "reasoning_effort"
        case serviceTier = "service_tier"
        case contextWindow = "context_window"
        case agentPreset = "agent_preset"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case lastReplyAt = "last_reply_at"
        case providerCursor = "provider_cursor"
        case availableCommands = "available_commands"
        case contextUsage = "context_usage"
        case runtimeEventCursor = "runtime_event_cursor"
        case transcriptBlocks = "transcript_blocks"
        case queuedMessages = "queued_messages"
    }

    public init(
        id: UUID = UUID(),
        title: String = AgentSession.defaultTitle,
        autoTitle: String? = nil,
        projectId: UUID,
        workspace: SessionWorkspace = .local,
        provider: ProviderKind,
        model: String? = nil,
        runtimeMode: RuntimeMode = .fullAccess,
        interactionMode: InteractionMode = .build,
        reasoningEffort: String? = nil,
        serviceTier: String? = nil,
        contextWindow: String? = nil,
        agentPreset: String? = nil,
        status: SessionStatus = .idle,
        createdAt: UInt64,
        updatedAt: UInt64,
        lastReplyAt: UInt64? = nil,
        providerCursor: JSONValue? = nil,
        availableCommands: [ReportedCommand] = [],
        contextUsage: ContextUsage? = nil,
        runtimeEventCursor: RuntimeEventCursor? = nil,
        messages: [Message] = [],
        transcriptBlocks: [TranscriptBlock] = [],
        turns: [AgentTurn] = [],
        queuedMessages: [QueuedMessage] = []
    ) {
        self.id = id
        self.title = title
        self.autoTitle = autoTitle
        self.projectId = projectId
        self.workspace = workspace
        self.provider = provider
        self.model = model
        self.runtimeMode = runtimeMode
        self.interactionMode = interactionMode
        self.reasoningEffort = reasoningEffort
        self.serviceTier = serviceTier
        self.contextWindow = contextWindow
        self.agentPreset = agentPreset
        self.status = status
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.lastReplyAt = lastReplyAt
        self.providerCursor = providerCursor
        self.availableCommands = availableCommands
        self.contextUsage = contextUsage
        self.runtimeEventCursor = runtimeEventCursor
        self.messages = messages
        self.transcriptBlocks = transcriptBlocks
        self.turns = turns
        self.queuedMessages = queuedMessages
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        autoTitle = try container.decodeIfPresent(String.self, forKey: .autoTitle)
        projectId = try container.decode(UUID.self, forKey: .projectId)
        workspace = try container.decodeIfPresent(SessionWorkspace.self, forKey: .workspace) ?? .local
        provider = try container.decode(ProviderKind.self, forKey: .provider)
        model = try container.decodeIfPresent(String.self, forKey: .model)
        runtimeMode = try container.decode(RuntimeMode.self, forKey: .runtimeMode)
        interactionMode = try container.decodeIfPresent(InteractionMode.self, forKey: .interactionMode) ?? .build
        reasoningEffort = try container.decodeIfPresent(String.self, forKey: .reasoningEffort)
        serviceTier = try container.decodeIfPresent(String.self, forKey: .serviceTier)
        contextWindow = try container.decodeIfPresent(String.self, forKey: .contextWindow)
        agentPreset = try container.decodeIfPresent(String.self, forKey: .agentPreset)
        status = try container.decode(SessionStatus.self, forKey: .status)
        createdAt = try container.decode(UInt64.self, forKey: .createdAt)
        updatedAt = try container.decode(UInt64.self, forKey: .updatedAt)
        lastReplyAt = try container.decodeIfPresent(UInt64.self, forKey: .lastReplyAt)
        let cursor = try container.decodeIfPresent(JSONValue.self, forKey: .providerCursor)
        providerCursor = cursor?.isNull == true ? nil : cursor
        availableCommands = try container.decodeIfPresent([ReportedCommand].self, forKey: .availableCommands) ?? []
        contextUsage = try container.decodeIfPresent(ContextUsage.self, forKey: .contextUsage)
        runtimeEventCursor = try container.decodeIfPresent(RuntimeEventCursor.self, forKey: .runtimeEventCursor)
        messages = try container.decodeIfPresent([Message].self, forKey: .messages) ?? []
        transcriptBlocks = try container.decodeIfPresent([TranscriptBlock].self, forKey: .transcriptBlocks) ?? []
        turns = try container.decodeIfPresent([AgentTurn].self, forKey: .turns) ?? []
        queuedMessages = try container.decodeIfPresent([QueuedMessage].self, forKey: .queuedMessages) ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id.wireString, forKey: .id)
        try container.encode(title, forKey: .title)
        try container.encodeIfPresent(autoTitle, forKey: .autoTitle)
        try container.encode(projectId.wireString, forKey: .projectId)
        if !workspace.isLocal {
            try container.encode(workspace, forKey: .workspace)
        }
        try container.encode(provider, forKey: .provider)
        try container.encodeIfPresent(model, forKey: .model)
        try container.encode(runtimeMode, forKey: .runtimeMode)
        try container.encode(interactionMode, forKey: .interactionMode)
        try container.encodeIfPresent(reasoningEffort, forKey: .reasoningEffort)
        try container.encodeIfPresent(serviceTier, forKey: .serviceTier)
        try container.encodeIfPresent(contextWindow, forKey: .contextWindow)
        try container.encodeIfPresent(agentPreset, forKey: .agentPreset)
        try container.encode(status, forKey: .status)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(updatedAt, forKey: .updatedAt)
        try container.encodeIfPresent(lastReplyAt, forKey: .lastReplyAt)
        try container.encode(providerCursor ?? .null, forKey: .providerCursor)
        if !availableCommands.isEmpty {
            try container.encode(availableCommands, forKey: .availableCommands)
        }
        try container.encodeIfPresent(contextUsage, forKey: .contextUsage)
        try container.encodeIfPresent(runtimeEventCursor, forKey: .runtimeEventCursor)
        try container.encode(messages, forKey: .messages)
        try container.encode(transcriptBlocks, forKey: .transcriptBlocks)
        try container.encode(turns, forKey: .turns)
        if !queuedMessages.isEmpty {
            try container.encode(queuedMessages, forKey: .queuedMessages)
        }
    }

    public var displayTitle: String {
        if title != Self.defaultTitle { return title }
        return autoTitle ?? title
    }

    /// A task the user has actually started. Drafts that never carried a
    /// prompt are the composer's business: they key their draft by project,
    /// and nothing about them is on the daemon yet. Port of the web client's
    /// `sessionHasStarted`.
    public var hasStarted: Bool {
        !turns.isEmpty || !messages.isEmpty || providerCursor != nil || lastReplyAt != nil
    }

    /// A turn the provider has acknowledged, so there is something to steer.
    /// Busy alone is not enough: a prompt still on its way to the provider has
    /// no turn, and a runtime that missed `turnStarted` must queue instead.
    /// Port of `sessionHasActiveProviderTurn`.
    public var hasActiveProviderTurn: Bool {
        guard status.isBusy, let turn = turns.last else { return false }
        return turn.status == .running && turn.providerTurnStarted
    }
}
