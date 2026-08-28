import Foundation

/// Decoded `ResponsePayload`. Only the variants the iOS client requests carry
/// typed data; anything else decodes to `.unknown` with the raw JSON retained.
public enum ResponsePayload: Sendable {
    case ack
    case sessionRuntime(runtimeId: UUID?, supportsSteer: Bool)
    case started(supportsSteer: Bool)
    case settings(DaemonSettings)
    case providerProbe(probe: ProviderProbe, version: String?)
    case taskState(
        projects: [Project],
        sessions: [AgentSession],
        defaultCwd: String,
        projectlessRoot: String?
    )
    case taskStateSaved(sessions: [AgentSession])
    case session(AgentSession?)
    case optionsApplied(Bool)
    case planUsage(PlanUsage?)
    case usageHistory(UsageHistory)
    case skillsCatalog(SkillsCatalog)
    case composerDrafts(ComposerDrafts)
    case blobStored(reference: String, path: String)
    case attachmentStored(StoredAttachment)
    case blobData(Data)
    case sessionForked(session: AgentSession, checkpointWarning: String?)
    case sessionRewound(session: AgentSession, cleanupWarning: String?)
    case workspace(WorkspaceResult)
    case unknown(type: String, raw: JSONValue)
}

extension ResponsePayload: Decodable {
    enum CodingKeys: String, CodingKey {
        case type, runtimeId, supportsSteer, settings, probe, version
        case projects, sessions, defaultCwd, projectlessRoot, session, bytes
        case checkpointWarning, cleanupWarning, result
        case applied, drafts, reference, path, attachment, usage, history, catalog
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "ack":
            self = .ack
        case "sessionRuntime":
            self = .sessionRuntime(
                runtimeId: try container.decodeIfPresent(UUID.self, forKey: .runtimeId),
                supportsSteer: try container.decode(Bool.self, forKey: .supportsSteer)
            )
        case "started":
            self = .started(supportsSteer: try container.decode(Bool.self, forKey: .supportsSteer))
        case "settings":
            self = .settings(try container.decode(DaemonSettings.self, forKey: .settings))
        case "providerProbe":
            self = .providerProbe(
                probe: try container.decode(ProviderProbe.self, forKey: .probe),
                version: try container.decodeIfPresent(String.self, forKey: .version)
            )
        case "taskState":
            self = .taskState(
                projects: try container.decode([Project].self, forKey: .projects),
                sessions: try container.decode([AgentSession].self, forKey: .sessions),
                defaultCwd: try container.decode(String.self, forKey: .defaultCwd),
                projectlessRoot: try container.decodeIfPresent(String.self, forKey: .projectlessRoot)
            )
        case "taskStateSaved":
            self = .taskStateSaved(sessions: try container.decode([AgentSession].self, forKey: .sessions))
        case "session":
            self = .session(try container.decodeIfPresent(AgentSession.self, forKey: .session))
        case "planUsage":
            self = .planUsage(try container.decodeIfPresent(PlanUsage.self, forKey: .usage))
        case "usageHistory":
            self = .usageHistory(try container.decode(UsageHistory.self, forKey: .history))
        case "skillsCatalog":
            self = .skillsCatalog(try container.decode(SkillsCatalog.self, forKey: .catalog))
        case "optionsApplied":
            self = .optionsApplied(try container.decode(Bool.self, forKey: .applied))
        case "composerDrafts":
            self = .composerDrafts(try container.decode(ComposerDrafts.self, forKey: .drafts))
        case "blobStored":
            self = .blobStored(
                reference: try container.decode(String.self, forKey: .reference),
                path: try container.decode(String.self, forKey: .path)
            )
        case "attachmentStored":
            self = .attachmentStored(
                try container.decode(StoredAttachment.self, forKey: .attachment))
        case "blobData":
            let encoded = try container.decode(String.self, forKey: .bytes)
            guard let data = Data(base64Encoded: encoded) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .bytes, in: container,
                    debugDescription: "blob bytes are not valid base64"
                )
            }
            self = .blobData(data)
        case "sessionForked":
            self = .sessionForked(
                session: try container.decode(AgentSession.self, forKey: .session),
                checkpointWarning: try container.decodeIfPresent(String.self, forKey: .checkpointWarning)
            )
        case "sessionRewound":
            self = .sessionRewound(
                session: try container.decode(AgentSession.self, forKey: .session),
                cleanupWarning: try container.decodeIfPresent(String.self, forKey: .cleanupWarning)
            )
        case "workspace":
            self = .workspace(try container.decode(WorkspaceResult.self, forKey: .result))
        default:
            let raw = (try? decoder.singleValueContainer().decode(JSONValue.self)) ?? .null
            self = .unknown(type: type, raw: raw)
        }
    }
}
