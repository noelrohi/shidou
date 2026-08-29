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

/// How the daemon should invoke a provider for a one-shot job — today only
/// commit-message generation. Encode-only: the client picks the provider.
public struct AgentInvocation: Encodable, Sendable {
    public var provider: ProviderKind
    public var binary: String
    public var model: String?
    public var reasoningEffort: String?

    enum CodingKeys: String, CodingKey {
        case provider, binary, model
        case reasoningEffort = "reasoning_effort"
    }

    public init(
        provider: ProviderKind,
        binary: String,
        model: String? = nil,
        reasoningEffort: String? = nil
    ) {
        self.provider = provider
        self.binary = binary
        self.model = model
        self.reasoningEffort = reasoningEffort
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(provider, forKey: .provider)
        try container.encode(binary, forKey: .binary)
        try container.encode(model, forKey: .model)
        try container.encode(reasoningEffort, forKey: .reasoningEffort)
    }
}

/// Which range of work a review diff covers. Externally tagged, and its
/// `rename_all` renames only the variants — `lastTurn`'s own fields stay
/// snake_case, like everything else in this module.
public enum ReviewDiffSource: Codable, Hashable, Sendable {
    case lastTurn(sessionId: UUID, turnId: UUID, turnCount: Int)
    case uncommitted
    case unstaged
    case staged
    case committed
    case branch

    private enum CodingKeys: String, CodingKey {
        case lastTurn
    }

    private struct LastTurn: Codable {
        var sessionId: UUID
        var turnId: UUID
        var turnCount: Int

        enum CodingKeys: String, CodingKey {
            case sessionId = "session_id"
            case turnId = "turn_id"
            case turnCount = "turn_count"
        }

        init(sessionId: UUID, turnId: UUID, turnCount: Int) {
            self.sessionId = sessionId
            self.turnId = turnId
            self.turnCount = turnCount
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            sessionId = try container.decode(UUID.self, forKey: .sessionId)
            turnId = try container.decode(UUID.self, forKey: .turnId)
            turnCount = try container.decode(Int.self, forKey: .turnCount)
        }

        // Lowercase, like every other id this client puts on the wire.
        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(sessionId.wireString, forKey: .sessionId)
            try container.encode(turnId.wireString, forKey: .turnId)
            try container.encode(turnCount, forKey: .turnCount)
        }
    }

    public init(from decoder: Decoder) throws {
        if let raw = try? decoder.singleValueContainer().decode(String.self) {
            switch raw {
            case "unstaged": self = .unstaged
            case "staged": self = .staged
            case "committed": self = .committed
            case "branch": self = .branch
            default: self = .uncommitted
            }
            return
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let turn = try container.decode(LastTurn.self, forKey: .lastTurn)
        self = .lastTurn(sessionId: turn.sessionId, turnId: turn.turnId, turnCount: turn.turnCount)
    }

    public func encode(to encoder: Encoder) throws {
        switch self {
        case .lastTurn(let sessionId, let turnId, let turnCount):
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(
                LastTurn(sessionId: sessionId, turnId: turnId, turnCount: turnCount),
                forKey: .lastTurn
            )
        case .uncommitted, .unstaged, .staged, .committed, .branch:
            var container = encoder.singleValueContainer()
            try container.encode(bareName)
        }
    }

    private var bareName: String {
        switch self {
        case .lastTurn: return "lastTurn"
        case .uncommitted: return "uncommitted"
        case .unstaged: return "unstaged"
        case .staged: return "staged"
        case .committed: return "committed"
        case .branch: return "branch"
        }
    }
}

/// NOTE: `ReviewDiffData` is a struct with `rename_all = "camelCase"`, so its
/// fields really are camelCase — unlike the operations that produce it.
public struct ReviewDiffData: Codable, Hashable, Sendable {
    public var source: ReviewDiffSource
    public var numstat: String
    public var patch: String
    public var completeContext: Bool
}

/// Working-copy state of a tree entry relative to the Git index. A directory
/// carries the strongest status found among its descendants.
public enum WorkingTreeStatus: String, WireStringEnum {
    case modified, untracked
    case unknown

    public static var unknownCase: Self { .unknown }
}

/// One row of a daemon directory listing. NOTE: unlike the enums around it,
/// this struct *does* carry `rename_all = "camelCase"`.
public struct WorkingTreeEntry: Codable, Hashable, Sendable, Identifiable {
    public var relativePath: String
    public var absolutePath: String
    public var name: String
    public var isDir: Bool
    public var expanded: Bool
    public var depth: Int
    public var status: WorkingTreeStatus?

    public var id: String { absolutePath }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        relativePath = try container.decode(String.self, forKey: .relativePath)
        absolutePath = try container.decode(String.self, forKey: .absolutePath)
        name = try container.decode(String.self, forKey: .name)
        isDir = try container.decode(Bool.self, forKey: .isDir)
        expanded = try container.decodeIfPresent(Bool.self, forKey: .expanded) ?? false
        depth = try container.decodeIfPresent(Int.self, forKey: .depth) ?? 0
        status = try container.decodeIfPresent(WorkingTreeStatus.self, forKey: .status)
    }
}

/// A directory as the daemon reports it, with the anchors a browser needs to
/// walk up and to jump home.
public struct DaemonDirectory: Sendable {
    public var path: String
    public var parent: String?
    public var home: String
    public var filesystemRoot: String
    public var entries: [WorkingTreeEntry]
}

/// The v1 subset of `WorkspaceOperation`. Encode-only.
public enum WorkspaceOperation: Sendable {
    case listTree(root: String, expandedPaths: [String])
    case browseDirectory(path: String?)
    case readTextFile(root: String, relativePath: String)
    case listProjectFiles(root: String, cap: Int)
    case discoverSlashCommands(provider: ProviderKind, projectRoot: String)
    case inspectBranches(cwd: String)
    case checkoutBranch(cwd: String, branch: String, create: Bool)
    case createProjectlessWorkspace(prompt: String?)
    case createWorktree(
        projectPath: String,
        projectId: UUID,
        sessionId: UUID,
        prompt: String,
        baseBranch: String?
    )
    case inspectCommit(cwd: String)
    case generateCommitMessage(
        cwd: String,
        includeUnstaged: Bool,
        conventionalCommits: Bool,
        invocation: AgentInvocation
    )
    case commit(cwd: String, message: String, includeUnstaged: Bool, push: Bool)
    case push(cwd: String)
    /// Which turn checkpoints this session still has refs for. A rewind is
    /// only offered where one exists, so the client asks before it offers.
    case sessionTurnRefs(cwd: String, sessionId: UUID)
    case captureTurnStart(cwd: String, sessionId: UUID, turnCount: Int)
    case captureTurn(cwd: String, sessionId: UUID, turnCount: Int)
    case captureRef(cwd: String, gitRef: String)
    case restoreRef(cwd: String, gitRef: String)
    case hasRef(cwd: String, gitRef: String)
    case collectReviewDiff(cwd: String, source: ReviewDiffSource)
}

extension WorkspaceOperation: Encodable {
    enum CodingKeys: String, CodingKey {
        case type, prompt, cwd, message, push, path, root, cap, provider, branch, create
        case source, invocation
        case expandedPaths = "expanded_paths"
        case relativePath = "relative_path"
        case conventionalCommits = "conventional_commits"
        case projectPath = "project_path"
        case projectId = "project_id"
        case sessionId = "session_id"
        case baseBranch = "base_branch"
        case includeUnstaged = "include_unstaged"
        case turnCount = "turn_count"
        case gitRef = "git_ref"
        case projectRoot = "project_root"
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .listTree(let root, let expandedPaths):
            try container.encode("listTree", forKey: .type)
            try container.encode(root, forKey: .root)
            try container.encode(expandedPaths, forKey: .expandedPaths)
        case .readTextFile(let root, let relativePath):
            try container.encode("readTextFile", forKey: .type)
            try container.encode(root, forKey: .root)
            try container.encode(relativePath, forKey: .relativePath)
        case .collectReviewDiff(let cwd, let source):
            try container.encode("collectReviewDiff", forKey: .type)
            try container.encode(cwd, forKey: .cwd)
            try container.encode(source, forKey: .source)
        case .generateCommitMessage(let cwd, let includeUnstaged, let conventionalCommits, let invocation):
            try container.encode("generateCommitMessage", forKey: .type)
            try container.encode(cwd, forKey: .cwd)
            try container.encode(includeUnstaged, forKey: .includeUnstaged)
            try container.encode(conventionalCommits, forKey: .conventionalCommits)
            try container.encode(invocation, forKey: .invocation)
        case .browseDirectory(let path):
            try container.encode("browseDirectory", forKey: .type)
            try container.encode(path, forKey: .path)
        case .listProjectFiles(let root, let cap):
            try container.encode("listProjectFiles", forKey: .type)
            try container.encode(root, forKey: .root)
            try container.encode(cap, forKey: .cap)
        case .discoverSlashCommands(let provider, let projectRoot):
            try container.encode("discoverSlashCommands", forKey: .type)
            try container.encode(provider, forKey: .provider)
            try container.encode(projectRoot, forKey: .projectRoot)
        case .inspectBranches(let cwd):
            try container.encode("inspectBranches", forKey: .type)
            try container.encode(cwd, forKey: .cwd)
        case .checkoutBranch(let cwd, let branch, let create):
            try container.encode("checkoutBranch", forKey: .type)
            try container.encode(cwd, forKey: .cwd)
            try container.encode(branch, forKey: .branch)
            try container.encode(create, forKey: .create)
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
        case .sessionTurnRefs(let cwd, let sessionId):
            try container.encode("sessionTurnRefs", forKey: .type)
            try container.encode(cwd, forKey: .cwd)
            try container.encode(sessionId.wireString, forKey: .sessionId)
        case .captureTurnStart(let cwd, let sessionId, let turnCount):
            try container.encode("captureTurnStart", forKey: .type)
            try container.encode(cwd, forKey: .cwd)
            try container.encode(sessionId.wireString, forKey: .sessionId)
            try container.encode(turnCount, forKey: .turnCount)
        case .captureTurn(let cwd, let sessionId, let turnCount):
            try container.encode("captureTurn", forKey: .type)
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
    case workingTree([WorkingTreeEntry])
    case directory(DaemonDirectory)
    case textFile(String)
    case projectFiles([FileEntry])
    case slashCommands([SlashCommand])
    case branches(BranchSnapshot?)
    case branchChanged(BranchSnapshot)
    case projectlessWorkspace(cwd: String)
    case worktreeCreated(CreatedWorktree)
    case commitSnapshot(CommitSnapshot)
    case commitMessage(String)
    case reviewDiff(ReviewDiffData)
    case checkpoint(Checkpoint)
    case turnRefs([Int])
    case bool(Bool)
    case unknown(type: String)
}

extension WorkspaceResult: Decodable {
    enum CodingKeys: String, CodingKey {
        case type, cwd, worktree, snapshot, checkpoint, value, content, message, data
        case path, parent, home, entries, commands
        case turnCounts = "turn_counts"
        case filesystemRoot = "filesystem_root"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "ack":
            self = .ack
        case "workingTree":
            self = .workingTree(try container.decode([WorkingTreeEntry].self, forKey: .entries))
        case "textFile":
            self = .textFile(try container.decode(String.self, forKey: .content))
        case "commitMessage":
            self = .commitMessage(try container.decode(String.self, forKey: .message))
        case "reviewDiff":
            self = .reviewDiff(try container.decode(ReviewDiffData.self, forKey: .data))
        case "directory":
            self = .directory(DaemonDirectory(
                path: try container.decode(String.self, forKey: .path),
                parent: try container.decodeIfPresent(String.self, forKey: .parent),
                home: try container.decode(String.self, forKey: .home),
                filesystemRoot: try container.decode(String.self, forKey: .filesystemRoot),
                entries: try container.decode([WorkingTreeEntry].self, forKey: .entries)
            ))
        case "projectFiles":
            self = .projectFiles(try container.decode([FileEntry].self, forKey: .entries))
        case "slashCommands":
            self = .slashCommands(try container.decode([SlashCommand].self, forKey: .commands))
        case "branches":
            self = .branches(try container.decodeIfPresent(BranchSnapshot.self, forKey: .snapshot))
        case "branchChanged":
            self = .branchChanged(try container.decode(BranchSnapshot.self, forKey: .snapshot))
        case "projectlessWorkspace":
            self = .projectlessWorkspace(cwd: try container.decode(String.self, forKey: .cwd))
        case "worktreeCreated":
            self = .worktreeCreated(try container.decode(CreatedWorktree.self, forKey: .worktree))
        case "commitSnapshot":
            self = .commitSnapshot(try container.decode(CommitSnapshot.self, forKey: .snapshot))
        case "checkpoint":
            self = .checkpoint(try container.decode(Checkpoint.self, forKey: .checkpoint))
        case "turnRefs":
            self = .turnRefs(try container.decode([Int].self, forKey: .turnCounts))
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
