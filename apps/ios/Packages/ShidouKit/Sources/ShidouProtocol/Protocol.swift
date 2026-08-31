import Foundation

/// Wire contract for the Shidou daemon, mirroring
/// `crates/shidou-protocol/src/protocol.rs`. The daemon enforces exact
/// protocol-version equality during the handshake.
public enum ShidouWire {
    public static let protocolVersion: UInt32 = 6
    public static let maxWireMessageBytes = 48 * 1024 * 1024
    public static let endpointPath = "/v1"
}

extension UUID {
    /// Rust's `uuid` crate serializes lowercase; it parses either case, but
    /// emitting lowercase keeps our frames byte-comparable with fixtures.
    public var wireString: String { uuidString.lowercased() }

    public static let zero = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))
}

public struct ReplayCursor: Codable, Hashable, Sendable {
    public var sessionId: UUID
    public var runtimeId: UUID
    public var epoch: UUID
    public var sequence: UInt64

    public init(sessionId: UUID, runtimeId: UUID, epoch: UUID, sequence: UInt64) {
        self.sessionId = sessionId
        self.runtimeId = runtimeId
        self.epoch = epoch
        self.sequence = sequence
    }
}

/// The daemon reporting that replay cannot make us whole for one session
/// runtime: everything below `firstAvailable` that we had not already seen was
/// evicted from its in-memory journal while we were away.
public struct ReplayGap: Hashable, Sendable {
    public var sessionId: UUID
    public var runtimeId: UUID
    public var epoch: UUID
    /// The oldest sequence the daemon still holds.
    public var firstAvailable: UInt64

    public init(sessionId: UUID, runtimeId: UUID, epoch: UUID, firstAvailable: UInt64) {
        self.sessionId = sessionId
        self.runtimeId = runtimeId
        self.epoch = epoch
        self.firstAvailable = firstAvailable
    }
}

public struct WireDriverEvent: Codable, Sendable {
    public var kind: String
    public var payload: JSONValue

    public init(kind: String, payload: JSONValue = .null) {
        self.kind = kind
        self.payload = payload
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        kind = try container.decode(String.self, forKey: .kind)
        payload = try container.decodeIfPresent(JSONValue.self, forKey: .payload) ?? .null
    }
}

public struct SequencedEvent: Codable, Sendable {
    public var sessionId: UUID
    public var runtimeId: UUID
    /// Changes whenever the daemon restarts, so a reused runtime id can begin
    /// again at sequence one without being mistaken for an old event.
    public var epoch: UUID
    public var sequence: UInt64
    public var event: WireDriverEvent

    public init(
        sessionId: UUID,
        runtimeId: UUID,
        epoch: UUID,
        sequence: UInt64,
        event: WireDriverEvent
    ) {
        self.sessionId = sessionId
        self.runtimeId = runtimeId
        self.epoch = epoch
        self.sequence = sequence
        self.event = event
    }
}

public struct Request: Sendable {
    public var requestId: UUID
    public var sessionId: UUID
    public var runtimeId: UUID
    public var command: Command

    public init(requestId: UUID = UUID(), sessionId: UUID = .zero, runtimeId: UUID = .zero, command: Command) {
        self.requestId = requestId
        self.sessionId = sessionId
        self.runtimeId = runtimeId
        self.command = command
    }
}

extension Request: Encodable {
    enum CodingKeys: String, CodingKey {
        case requestId, sessionId, runtimeId, command
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(requestId.wireString, forKey: .requestId)
        try container.encode(sessionId.wireString, forKey: .sessionId)
        try container.encode(runtimeId.wireString, forKey: .runtimeId)
        try container.encode(command, forKey: .command)
    }
}

public enum ClientMessage: Sendable {
    case hello(token: String, clientId: UUID, resumeFrom: [ReplayCursor])
    case request(Request)
    case shutdown
}

extension ClientMessage: Encodable {
    enum CodingKeys: String, CodingKey {
        case type, protocolVersion, token, clientId, resumeFrom
        case requestId, sessionId, runtimeId, command
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .hello(let token, let clientId, let resumeFrom):
            try container.encode("hello", forKey: .type)
            try container.encode(ShidouWire.protocolVersion, forKey: .protocolVersion)
            try container.encode(token, forKey: .token)
            try container.encode(clientId.wireString, forKey: .clientId)
            try container.encode(resumeFrom.map(WireReplayCursor.init), forKey: .resumeFrom)
        case .request(let request):
            try container.encode("request", forKey: .type)
            try container.encode(request.requestId.wireString, forKey: .requestId)
            try container.encode(request.sessionId.wireString, forKey: .sessionId)
            try container.encode(request.runtimeId.wireString, forKey: .runtimeId)
            try container.encode(request.command, forKey: .command)
        case .shutdown:
            try container.encode("shutdown", forKey: .type)
        }
    }
}

/// Encodes replay cursors with lowercase UUID strings.
struct WireReplayCursor: Encodable {
    let cursor: ReplayCursor

    init(_ cursor: ReplayCursor) { self.cursor = cursor }

    enum CodingKeys: String, CodingKey {
        case sessionId, runtimeId, epoch, sequence
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(cursor.sessionId.wireString, forKey: .sessionId)
        try container.encode(cursor.runtimeId.wireString, forKey: .runtimeId)
        try container.encode(cursor.epoch.wireString, forKey: .epoch)
        try container.encode(cursor.sequence, forKey: .sequence)
    }
}

public struct RpcError: Codable, Error, Sendable {
    public var message: String

    public init(message: String) { self.message = message }
}

public enum ResponseOutcome: Sendable {
    case ok(ResponsePayload)
    case error(RpcError)
}

extension ResponseOutcome: Decodable {
    enum CodingKeys: String, CodingKey {
        case status, payload, error
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let status = try container.decode(String.self, forKey: .status)
        switch status {
        case "ok":
            self = .ok(try container.decode(ResponsePayload.self, forKey: .payload))
        case "error":
            self = .error(try container.decode(RpcError.self, forKey: .error))
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .status, in: container,
                debugDescription: "unknown response status \(status)"
            )
        }
    }
}

public enum ServerMessage: Sendable {
    case hello(protocolVersion: UInt32, daemonVersion: String)
    case rejected(message: String)
    case response(requestId: UUID, outcome: ResponseOutcome)
    case event(SequencedEvent)
    /// Our replay cursor fell off the back of the daemon's journal. The events
    /// between it and `firstAvailable` are gone, so the tail that follows
    /// cannot be applied to the projection we are holding — the session has to
    /// be refetched instead.
    case replayGap(ReplayGap)
    /// The daemon-owned project/task catalog changed through another client.
    case taskStateChanged(revision: UInt64)
    case shuttingDown
    /// A message type this build does not know. A newer daemon must not kill
    /// the connection, so unknown types decode instead of throwing.
    case unknown(type: String)
}

extension ServerMessage: Decodable {
    enum CodingKeys: String, CodingKey {
        case type, protocolVersion, daemonVersion, message, requestId, outcome
        case sessionId, runtimeId, epoch, sequence, event, revision, firstAvailable
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "hello":
            self = .hello(
                protocolVersion: try container.decode(UInt32.self, forKey: .protocolVersion),
                daemonVersion: try container.decode(String.self, forKey: .daemonVersion)
            )
        case "rejected":
            self = .rejected(message: try container.decode(String.self, forKey: .message))
        case "response":
            self = .response(
                requestId: try container.decode(UUID.self, forKey: .requestId),
                outcome: try container.decode(ResponseOutcome.self, forKey: .outcome)
            )
        case "event":
            self = .event(SequencedEvent(
                sessionId: try container.decode(UUID.self, forKey: .sessionId),
                runtimeId: try container.decode(UUID.self, forKey: .runtimeId),
                epoch: try container.decode(UUID.self, forKey: .epoch),
                sequence: try container.decode(UInt64.self, forKey: .sequence),
                event: try container.decode(WireDriverEvent.self, forKey: .event)
            ))
        case "replayGap":
            self = .replayGap(ReplayGap(
                sessionId: try container.decode(UUID.self, forKey: .sessionId),
                runtimeId: try container.decode(UUID.self, forKey: .runtimeId),
                epoch: try container.decode(UUID.self, forKey: .epoch),
                firstAvailable: try container.decode(UInt64.self, forKey: .firstAvailable)
            ))
        case "taskStateChanged":
            self = .taskStateChanged(revision: try container.decode(UInt64.self, forKey: .revision))
        case "shuttingDown":
            self = .shuttingDown
        default:
            self = .unknown(type: type)
        }
    }
}
