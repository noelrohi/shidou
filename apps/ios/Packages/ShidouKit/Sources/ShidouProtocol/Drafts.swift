import Foundation

// Mirrors `crates/shidou-protocol/src/persistence.rs`. `ComposerDraft` and
// `ComposerDraftAttachment` carry no `rename_all`, so their fields are
// snake_case and the attachment is wire-identical to `MessageAttachment` —
// which is why a draft's attachments are that type here rather than a second
// copy of the same six fields.

public struct ComposerDraft: Codable, Hashable, Sendable {
    public var text: String
    public var attachments: [MessageAttachment]

    public init(text: String = "", attachments: [MessageAttachment] = []) {
        self.text = text
        self.attachments = attachments
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        text = try container.decodeIfPresent(String.self, forKey: .text) ?? ""
        attachments =
            try container.decodeIfPresent([MessageAttachment].self, forKey: .attachments) ?? []
    }

    public var isEmpty: Bool { text.isEmpty && attachments.isEmpty }
}

/// Which composer a draft belongs to. A task that has not started keys by its
/// project, because it has no identity the daemon knows yet.
public enum ComposerDraftKey: Hashable, Sendable {
    case newSession(projectId: UUID)
    case session(sessionId: UUID)

    public static func forSession(_ session: AgentSession) -> ComposerDraftKey {
        session.hasStarted
            ? .session(sessionId: session.id)
            : .newSession(projectId: session.projectId)
    }
}

/// Wire form of `ComposerDraftKey`. Tagged `type` with camelCase fields.
extension ComposerDraftKey: Encodable {
    enum CodingKeys: String, CodingKey {
        case type, projectId, sessionId
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .newSession(let projectId):
            try container.encode("newSession", forKey: .type)
            try container.encode(projectId.wireString, forKey: .projectId)
        case .session(let sessionId):
            try container.encode("session", forKey: .type)
            try container.encode(sessionId.wireString, forKey: .sessionId)
        }
    }
}

public struct ComposerDraftChange: Encodable, Sendable {
    public var target: ComposerDraftKey
    /// `nil` removes the target. An empty draft is normalized to removal too.
    public var draft: ComposerDraft?

    public init(target: ComposerDraftKey, draft: ComposerDraft?) {
        self.target = target
        self.draft = draft
    }
}

/// Every draft the daemon holds for this user, keyed the two ways a composer
/// can be identified.
public struct ComposerDrafts: Codable, Sendable {
    public var newSessions: [UUID: ComposerDraft]
    public var sessions: [UUID: ComposerDraft]

    public init(newSessions: [UUID: ComposerDraft] = [:], sessions: [UUID: ComposerDraft] = [:]) {
        self.newSessions = newSessions
        self.sessions = sessions
    }

    enum CodingKeys: String, CodingKey {
        case newSessions = "new_sessions"
        case sessions
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        newSessions = Self.decodeMap(
            try container.decodeIfPresent([String: ComposerDraft].self, forKey: .newSessions))
        sessions = Self.decodeMap(
            try container.decodeIfPresent([String: ComposerDraft].self, forKey: .sessions))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Self.encodeMap(newSessions), forKey: .newSessions)
        try container.encode(Self.encodeMap(sessions), forKey: .sessions)
    }

    public subscript(key: ComposerDraftKey) -> ComposerDraft? {
        get {
            switch key {
            case .newSession(let projectId): return newSessions[projectId]
            case .session(let sessionId): return sessions[sessionId]
            }
        }
        set {
            switch key {
            case .newSession(let projectId): newSessions[projectId] = newValue
            case .session(let sessionId): sessions[sessionId] = newValue
            }
        }
    }

    private static func decodeMap(_ raw: [String: ComposerDraft]?) -> [UUID: ComposerDraft] {
        var result: [UUID: ComposerDraft] = [:]
        for (key, value) in raw ?? [:] {
            guard let id = UUID(uuidString: key) else { continue }
            result[id] = value
        }
        return result
    }

    private static func encodeMap(_ map: [UUID: ComposerDraft]) -> [String: ComposerDraft] {
        var result: [String: ComposerDraft] = [:]
        for (key, value) in map { result[key.wireString] = value }
        return result
    }
}
