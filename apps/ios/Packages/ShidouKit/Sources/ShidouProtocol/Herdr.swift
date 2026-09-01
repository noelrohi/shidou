import Foundation

public enum HerdrAgentStatus: String, Codable, Hashable, Sendable {
    case idle, working, blocked, done, unknown
}

public struct HerdrAgentSession: Codable, Hashable, Sendable {
    public var source: String
    public var agent: String
    public var kind: String
    public var value: String
}

public struct HerdrWorktree: Codable, Hashable, Sendable {
    public var repoName: String
    public var repoRoot: String
    public var checkoutPath: String
    public var isLinkedWorktree: Bool

    enum CodingKeys: String, CodingKey {
        case repoName = "repo_name"
        case repoRoot = "repo_root"
        case checkoutPath = "checkout_path"
        case isLinkedWorktree = "is_linked_worktree"
    }
}

public struct HerdrWorkspace: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var label: String
    public var focused: Bool
    public var paneCount: Int
    public var tabCount: Int
    public var status: HerdrAgentStatus
    public var worktree: HerdrWorktree?

    enum CodingKeys: String, CodingKey {
        case id, label, focused, status, worktree
        case paneCount = "pane_count"
        case tabCount = "tab_count"
    }
}

public struct HerdrAgent: Codable, Identifiable, Hashable, Sendable {
    public var paneId: String
    public var terminalId: String
    public var workspaceId: String
    public var tabId: String
    public var agent: String
    public var name: String?
    public var title: String?
    public var cwd: String?
    public var status: HerdrAgentStatus
    public var focused: Bool
    public var revision: UInt64
    public var providerSession: HerdrAgentSession?

    public var id: String { terminalId }
    public var displayTitle: String { title ?? name ?? agent }

    enum CodingKeys: String, CodingKey {
        case agent, name, title, cwd, status, focused, revision
        case paneId = "pane_id"
        case terminalId = "terminal_id"
        case workspaceId = "workspace_id"
        case tabId = "tab_id"
        case providerSession = "provider_session"
    }
}

public struct HerdrState: Codable, Equatable, Sendable {
    public var available: Bool
    public var version: String?
    public var `protocol`: UInt32?
    public var workspaces: [HerdrWorkspace]
    public var agents: [HerdrAgent]
    public var unavailableReason: String?

    enum CodingKeys: String, CodingKey {
        case available, version, `protocol`, workspaces, agents
        case unavailableReason = "unavailable_reason"
    }

    public init(
        available: Bool,
        version: String?,
        protocol: UInt32?,
        workspaces: [HerdrWorkspace],
        agents: [HerdrAgent],
        unavailableReason: String?
    ) {
        self.available = available
        self.version = version
        self.protocol = `protocol`
        self.workspaces = workspaces
        self.agents = agents
        self.unavailableReason = unavailableReason
    }
}

public struct HerdrAgentOutput: Codable, Equatable, Sendable {
    public var paneId: String
    public var text: String
    public var revision: UInt64
    public var truncated: Bool

    enum CodingKeys: String, CodingKey {
        case text, revision, truncated
        case paneId = "pane_id"
    }
}
