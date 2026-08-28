import Foundation

/// Provider start options for `Command.start`, mirroring
/// `WireDriverStartOptions` (camelCase fields).
public struct DriverStartOptions: Encodable, Sendable {
    public var provider: String
    public var binary: String
    public var cwd: String
    public var mode: RuntimeMode
    public var interactionMode: InteractionMode
    public var model: String?
    public var reasoningEffort: String?
    public var serviceTier: String?
    public var contextWindow: String?
    public var agentPreset: String?
    public var computerUseEnabled: Bool
    public var providerCursor: JSONValue?

    public init(
        provider: String,
        binary: String,
        cwd: String,
        mode: RuntimeMode,
        interactionMode: InteractionMode,
        model: String? = nil,
        reasoningEffort: String? = nil,
        serviceTier: String? = nil,
        contextWindow: String? = nil,
        agentPreset: String? = nil,
        computerUseEnabled: Bool = false,
        providerCursor: JSONValue? = nil
    ) {
        self.provider = provider
        self.binary = binary
        self.cwd = cwd
        self.mode = mode
        self.interactionMode = interactionMode
        self.model = model
        self.reasoningEffort = reasoningEffort
        self.serviceTier = serviceTier
        self.contextWindow = contextWindow
        self.agentPreset = agentPreset
        self.computerUseEnabled = computerUseEnabled
        self.providerCursor = providerCursor
    }

    enum CodingKeys: String, CodingKey {
        case provider, binary, cwd, mode, interactionMode, model, reasoningEffort
        case serviceTier, contextWindow, agentPreset, computerUseEnabled, providerCursor
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(provider, forKey: .provider)
        try container.encode(binary, forKey: .binary)
        try container.encode(cwd, forKey: .cwd)
        try container.encode(mode, forKey: .mode)
        try container.encode(interactionMode, forKey: .interactionMode)
        try container.encode(model, forKey: .model)
        try container.encode(reasoningEffort, forKey: .reasoningEffort)
        try container.encode(serviceTier, forKey: .serviceTier)
        try container.encode(contextWindow, forKey: .contextWindow)
        try container.encode(agentPreset, forKey: .agentPreset)
        try container.encode(computerUseEnabled, forKey: .computerUseEnabled)
        try container.encode(providerCursor ?? .null, forKey: .providerCursor)
    }
}

/// Options a started runtime can be re-tuned with mid-session, mirroring
/// `WireSessionOptions` (camelCase fields).
public struct SessionOptions: Encodable, Sendable {
    public var mode: RuntimeMode
    public var interactionMode: InteractionMode
    public var model: String?
    public var reasoningEffort: String?
    public var serviceTier: String?
    public var contextWindow: String?

    public init(
        mode: RuntimeMode,
        interactionMode: InteractionMode,
        model: String? = nil,
        reasoningEffort: String? = nil,
        serviceTier: String? = nil,
        contextWindow: String? = nil
    ) {
        self.mode = mode
        self.interactionMode = interactionMode
        self.model = model
        self.reasoningEffort = reasoningEffort
        self.serviceTier = serviceTier
        self.contextWindow = contextWindow
    }

    enum CodingKeys: String, CodingKey {
        case mode, interactionMode, model, reasoningEffort, serviceTier, contextWindow
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(mode, forKey: .mode)
        try container.encode(interactionMode, forKey: .interactionMode)
        try container.encode(model, forKey: .model)
        try container.encode(reasoningEffort, forKey: .reasoningEffort)
        try container.encode(serviceTier, forKey: .serviceTier)
        try container.encode(contextWindow, forKey: .contextWindow)
    }

    public init(session: AgentSession) {
        self.init(
            mode: session.runtimeMode,
            interactionMode: session.interactionMode,
            model: session.model,
            reasoningEffort: session.reasoningEffort,
            serviceTier: session.serviceTier,
            contextWindow: session.contextWindow
        )
    }
}

/// The v1 subset of the daemon's `Command` enum. Encode-only: clients never
/// decode commands. Tag and fields are camelCase.
public enum Command: Sendable {
    case attachSession
    case start(options: DriverStartOptions)
    case prompt(String)
    case steer(String)
    case cancel
    case respond(requestId: String, optionId: String)
    case respondUserInput(requestId: String, answers: [UserInputAnswer])
    case applyOptions(SessionOptions)
    case getSettings
    case probeProvider(
        provider: ProviderKind,
        binaryOverride: String?,
        discoverModels: Bool,
        probeVersion: Bool
    )
    case fetchPlanUsage(provider: ProviderKind, binaryOverride: String?, cliVersion: String?)
    case loadTaskState
    case saveTaskState(projects: [Project], liveSessionIds: [UUID], sessions: [AgentSession])
    case removeSession
    case hydrateSession(sessionId: UUID)
    case loadComposerDrafts
    case saveComposerDrafts(drafts: ComposerDrafts, generation: UInt64)
    case applyComposerDraftChanges(changes: [ComposerDraftChange])
    case storeBlob(mimeType: String, bytes: Data)
    case importAttachment(name: String, upload: AttachmentUpload)
    case importPathAttachment(path: String)
    case readBlob(reference: String)
    case readAttachment(reference: String, path: String)
    case forkSessionFromResponse(turnCount: Int)
    case rewindSessionToMessage(turnCount: Int)
    case workspace(WorkspaceOperation)
    case closeSession
}

extension Command: Encodable {
    enum CodingKeys: String, CodingKey {
        case type, options, prompt, requestId, optionId, answers, provider
        case binaryOverride, discoverModels, probeVersion
        case projects, liveSessionIds, sessions, sessionId, reference, path
        case turnCount, operation
        case drafts, generation, changes, mimeType, bytes, name, upload
        case cliVersion
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .attachSession:
            try container.encode("attachSession", forKey: .type)
        case .start(let options):
            try container.encode("start", forKey: .type)
            try container.encode(options, forKey: .options)
        case .prompt(let prompt):
            try container.encode("prompt", forKey: .type)
            try container.encode(prompt, forKey: .prompt)
        case .steer(let prompt):
            try container.encode("steer", forKey: .type)
            try container.encode(prompt, forKey: .prompt)
        case .cancel:
            try container.encode("cancel", forKey: .type)
        case .respond(let requestId, let optionId):
            try container.encode("respond", forKey: .type)
            try container.encode(requestId, forKey: .requestId)
            try container.encode(optionId, forKey: .optionId)
        case .respondUserInput(let requestId, let answers):
            try container.encode("respondUserInput", forKey: .type)
            try container.encode(requestId, forKey: .requestId)
            try container.encode(answers, forKey: .answers)
        case .applyOptions(let options):
            try container.encode("applyOptions", forKey: .type)
            try container.encode(options, forKey: .options)
        case .getSettings:
            try container.encode("getSettings", forKey: .type)
        case .probeProvider(let provider, let binaryOverride, let discoverModels, let probeVersion):
            try container.encode("probeProvider", forKey: .type)
            try container.encode(provider, forKey: .provider)
            try container.encode(binaryOverride, forKey: .binaryOverride)
            try container.encode(discoverModels, forKey: .discoverModels)
            try container.encode(probeVersion, forKey: .probeVersion)
        case .fetchPlanUsage(let provider, let binaryOverride, let cliVersion):
            try container.encode("fetchPlanUsage", forKey: .type)
            try container.encode(provider, forKey: .provider)
            try container.encode(binaryOverride, forKey: .binaryOverride)
            try container.encode(cliVersion, forKey: .cliVersion)
        case .loadTaskState:
            try container.encode("loadTaskState", forKey: .type)
        case .saveTaskState(let projects, let liveSessionIds, let sessions):
            try container.encode("saveTaskState", forKey: .type)
            try container.encode(projects, forKey: .projects)
            try container.encode(liveSessionIds.map(\.wireString), forKey: .liveSessionIds)
            try container.encode(sessions, forKey: .sessions)
        case .removeSession:
            try container.encode("removeSession", forKey: .type)
        case .hydrateSession(let sessionId):
            try container.encode("hydrateSession", forKey: .type)
            try container.encode(sessionId.wireString, forKey: .sessionId)
        case .loadComposerDrafts:
            try container.encode("loadComposerDrafts", forKey: .type)
        case .saveComposerDrafts(let drafts, let generation):
            try container.encode("saveComposerDrafts", forKey: .type)
            try container.encode(drafts, forKey: .drafts)
            try container.encode(generation, forKey: .generation)
        case .applyComposerDraftChanges(let changes):
            try container.encode("applyComposerDraftChanges", forKey: .type)
            try container.encode(changes, forKey: .changes)
        case .storeBlob(let mimeType, let bytes):
            try container.encode("storeBlob", forKey: .type)
            try container.encode(mimeType, forKey: .mimeType)
            try container.encode(bytes.base64EncodedString(), forKey: .bytes)
        case .importAttachment(let name, let upload):
            try container.encode("importAttachment", forKey: .type)
            try container.encode(name, forKey: .name)
            try container.encode(upload, forKey: .upload)
        case .importPathAttachment(let path):
            try container.encode("importPathAttachment", forKey: .type)
            try container.encode(path, forKey: .path)
        case .readBlob(let reference):
            try container.encode("readBlob", forKey: .type)
            try container.encode(reference, forKey: .reference)
        case .readAttachment(let reference, let path):
            try container.encode("readAttachment", forKey: .type)
            try container.encode(reference, forKey: .reference)
            try container.encode(path, forKey: .path)
        case .forkSessionFromResponse(let turnCount):
            try container.encode("forkSessionFromResponse", forKey: .type)
            try container.encode(turnCount, forKey: .turnCount)
        case .rewindSessionToMessage(let turnCount):
            try container.encode("rewindSessionToMessage", forKey: .type)
            try container.encode(turnCount, forKey: .turnCount)
        case .workspace(let operation):
            try container.encode("workspace", forKey: .type)
            try container.encode(operation, forKey: .operation)
        case .closeSession:
            try container.encode("closeSession", forKey: .type)
        }
    }
}
