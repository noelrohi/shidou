import Foundation

// Mirrors `crates/shidou-protocol/src/workspace.rs` and `git.rs`. NOTE: the
// workspace enums tag with camelCase `type` but their FIELDS stay snake_case —
// they have no `rename_all_fields`.

public struct CommitSnapshot: Codable, Hashable, Sendable {
    public var branch: String
    public var additions: UInt64
    public var deletions: UInt64
    public var stagedAdditions: UInt64
    public var stagedDeletions: UInt64
    public var hasStaged: Bool
    public var hasUnstaged: Bool
    public var canPush: Bool

    enum CodingKeys: String, CodingKey {
        case branch, additions, deletions
        case stagedAdditions = "staged_additions"
        case stagedDeletions = "staged_deletions"
        case hasStaged = "has_staged"
        case hasUnstaged = "has_unstaged"
        case canPush = "can_push"
    }
}

public struct CreatedWorktree: Codable, Hashable, Sendable {
    public var path: String
    public var branch: String
}

/// The v1 subset of `WorkspaceOperation`. Encode-only.
public enum WorkspaceOperation: Sendable {
    case createProjectlessWorkspace(prompt: String?)
    case createWorktree(
        projectPath: String,
        projectId: UUID,
        sessionId: UUID,
        prompt: String,
        baseBranch: String?
    )
    case inspectCommit(cwd: String)
    case commit(cwd: String, message: String, includeUnstaged: Bool, push: Bool)
    case push(cwd: String)
    case captureTurnStart(cwd: String, sessionId: UUID, turnCount: Int)
    case captureRef(cwd: String, gitRef: String)
    case restoreRef(cwd: String, gitRef: String)
    case hasRef(cwd: String, gitRef: String)
}

extension WorkspaceOperation: Encodable {
    enum CodingKeys: String, CodingKey {
        case type, prompt, cwd, message, push
        case projectPath = "project_path"
        case projectId = "project_id"
        case sessionId = "session_id"
        case baseBranch = "base_branch"
        case includeUnstaged = "include_unstaged"
        case turnCount = "turn_count"
        case gitRef = "git_ref"
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .createProjectlessWorkspace(let prompt):
            try container.encode("createProjectlessWorkspace", forKey: .type)
            try container.encode(prompt, forKey: .prompt)
        case .createWorktree(let projectPath, let projectId, let sessionId, let prompt, let baseBranch):
            try container.encode("createWorktree", forKey: .type)
            try container.encode(projectPath, forKey: .projectPath)
            try container.encode(projectId.wireString, forKey: .projectId)
            try container.encode(sessionId.wireString, forKey: .sessionId)
            try container.encode(prompt, forKey: .prompt)
            try container.encode(baseBranch, forKey: .baseBranch)
        case .inspectCommit(let cwd):
            try container.encode("inspectCommit", forKey: .type)
            try container.encode(cwd, forKey: .cwd)
        case .commit(let cwd, let message, let includeUnstaged, let push):
            try container.encode("commit", forKey: .type)
            try container.encode(cwd, forKey: .cwd)
            try container.encode(message, forKey: .message)
            try container.encode(includeUnstaged, forKey: .includeUnstaged)
            try container.encode(push, forKey: .push)
        case .push(let cwd):
            try container.encode("push", forKey: .type)
            try container.encode(cwd, forKey: .cwd)
        case .captureTurnStart(let cwd, let sessionId, let turnCount):
            try container.encode("captureTurnStart", forKey: .type)
            try container.encode(cwd, forKey: .cwd)
            try container.encode(sessionId.wireString, forKey: .sessionId)
            try container.encode(turnCount, forKey: .turnCount)
        case .captureRef(let cwd, let gitRef):
            try container.encode("captureRef", forKey: .type)
            try container.encode(cwd, forKey: .cwd)
            try container.encode(gitRef, forKey: .gitRef)
        case .restoreRef(let cwd, let gitRef):
            try container.encode("restoreRef", forKey: .type)
            try container.encode(cwd, forKey: .cwd)
            try container.encode(gitRef, forKey: .gitRef)
        case .hasRef(let cwd, let gitRef):
            try container.encode("hasRef", forKey: .type)
            try container.encode(cwd, forKey: .cwd)
            try container.encode(gitRef, forKey: .gitRef)
        }
    }
}

/// Decoded `WorkspaceResult`. Unknown variants become `.unknown` so a newer
/// daemon cannot break decoding of an unrelated response.
public enum WorkspaceResult: Sendable {
    case ack
    case projectlessWorkspace(cwd: String)
    case worktreeCreated(CreatedWorktree)
    case commitSnapshot(CommitSnapshot)
    case checkpoint(Checkpoint)
    case bool(Bool)
    case unknown(type: String)
}

extension WorkspaceResult: Decodable {
    enum CodingKeys: String, CodingKey {
        case type, cwd, worktree, snapshot, checkpoint, value
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "ack":
            self = .ack
        case "projectlessWorkspace":
            self = .projectlessWorkspace(cwd: try container.decode(String.self, forKey: .cwd))
        case "worktreeCreated":
            self = .worktreeCreated(try container.decode(CreatedWorktree.self, forKey: .worktree))
        case "commitSnapshot":
            self = .commitSnapshot(try container.decode(CommitSnapshot.self, forKey: .snapshot))
        case "checkpoint":
            self = .checkpoint(try container.decode(Checkpoint.self, forKey: .checkpoint))
        case "bool":
            self = .bool(try container.decode(Bool.self, forKey: .value))
        default:
            self = .unknown(type: type)
        }
    }
}

public enum CheckpointRefs {
    /// Mirrors `crates/shidou-protocol/src/checkpoint.rs`.
    public static func turnRef(sessionId: UUID, turnCount: Int) -> String {
        "refs/shidou/session-\(sessionId.wireString)-turn-\(turnCount)"
    }

    public static func revertBackupRef(sessionId: UUID, unixTime: UInt64) -> String {
        "refs/shidou/revert-backup-\(sessionId.wireString)-\(unixTime)"
    }
}
