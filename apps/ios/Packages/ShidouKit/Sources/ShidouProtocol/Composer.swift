import Foundation

// Mirrors `crates/shidou-protocol/src/composer.rs` and `git.rs`. Neither
// carries a serde `rename_all`, so their fields stay snake_case — and
// `CommandScope` has no rename either, so its values are PascalCase.

public enum CommandScope: String, WireStringEnum {
    case project = "Project"
    case user = "User"
    case skill = "Skill"
    case builtin = "Builtin"
    case unknown = "Unknown"

    public static var unknownCase: Self { .unknown }

    /// Presentation order in the composer's suggestion list. Resolution
    /// precedence is a separate matter: a project or user command can still
    /// override a less specific one with the same name.
    public var displayRank: Int {
        switch self {
        case .builtin: return 0
        case .project: return 1
        case .user: return 2
        case .skill: return 3
        case .unknown: return 4
        }
    }
}

public struct SlashCommand: Codable, Hashable, Sendable, Identifiable {
    public var name: String
    public var description: String
    public var scope: CommandScope
    public var argumentHint: String?
    public var template: String?

    public var id: String { "\(scope.rawValue):\(name)" }

    enum CodingKeys: String, CodingKey {
        case name, description, scope, template
        case argumentHint = "argument_hint"
    }

    public init(
        name: String,
        description: String,
        scope: CommandScope,
        argumentHint: String? = nil,
        template: String? = nil
    ) {
        self.name = name
        self.description = description
        self.scope = scope
        self.argumentHint = argumentHint
        self.template = template
    }
}

public struct FileEntry: Codable, Hashable, Sendable, Identifiable {
    public var path: String
    public var isDir: Bool

    public var id: String { path }

    enum CodingKeys: String, CodingKey {
        case path
        case isDir = "is_dir"
    }

    public init(path: String, isDir: Bool) {
        self.path = path
        self.isDir = isDir
    }
}

public struct BranchEntry: Codable, Hashable, Sendable, Identifiable {
    public var name: String
    public var checkedOutElsewhere: Bool

    public var id: String { name }

    enum CodingKeys: String, CodingKey {
        case name
        case checkedOutElsewhere = "checked_out_elsewhere"
    }

    public init(name: String, checkedOutElsewhere: Bool) {
        self.name = name
        self.checkedOutElsewhere = checkedOutElsewhere
    }
}

public struct BranchSnapshot: Codable, Hashable, Sendable {
    public var repository: String
    public var current: String?
    public var detachedHead: String?
    public var defaultBranch: String?
    public var branches: [BranchEntry]
    public var additions: UInt64
    public var deletions: UInt64

    enum CodingKeys: String, CodingKey {
        case repository, current, branches, additions, deletions
        case detachedHead = "detached_head"
        case defaultBranch = "default_branch"
    }

    public init(
        repository: String,
        current: String? = nil,
        detachedHead: String? = nil,
        defaultBranch: String? = nil,
        branches: [BranchEntry] = [],
        additions: UInt64 = 0,
        deletions: UInt64 = 0
    ) {
        self.repository = repository
        self.current = current
        self.detachedHead = detachedHead
        self.defaultBranch = defaultBranch
        self.branches = branches
        self.additions = additions
        self.deletions = deletions
    }

    public var displayBranch: String? { current ?? detachedHead }
}

/// Mirrors `crates/shidou-protocol/src/usage.rs`. Unlike its neighbours here,
/// `PlanUsage` *does* carry `rename_all = "camelCase"`.
public struct PlanWindow: Codable, Hashable, Sendable, Identifiable {
    public var label: String
    public var percent: Double
    public var resetsAt: Int64?

    public var id: String { "\(label)-\(resetsAt ?? 0)" }
}

public struct PlanUsage: Codable, Hashable, Sendable {
    public var planLabel: String?
    public var windows: [PlanWindow]
}
