import Foundation

/// Typed view of `WireDriverEvent`, mirroring the daemon's
/// `event_from_wire` in `crates/shidou-protocol/src/driver_wire.rs`.
/// Kinds this client doesn't render decode to `.ignored`; kinds it doesn't
/// know decode to `.unknown` — neither may ever throw.
public enum DriverEvent: Sendable {
    case connected(providerCursor: JSONValue?)
    case autoTitleUpdated(String?)
    case availableCommands([ReportedCommand])
    case turnStarted
    case textDelta(String)
    case reasoningDelta(String)
    case activity(id: String?, kind: ActivityKind, title: String, detail: String?, complete: Bool)
    case richActivity(ActivityItem)
    case permission(requestId: String, title: String, detail: String, options: [PermissionOption])
    case userInputRequested(requestId: String, questions: [UserInputQuestion])
    case steerAccepted(message: String)
    case steerRejected(message: String, reason: String)
    case usageUpdated(contextTokens: UInt64?, contextWindow: UInt64?)
    case turnFinished(success: Bool, summary: String?)
    case error(String)
    case processExited
    /// A kind this client recognizes but deliberately does not handle
    /// (backgroundWork, computerUseUpdated, planUsageUpdated, …).
    case ignored(kind: String)
    case unknown(kind: String)
}

extension DriverEvent {
    private static let ignoredKinds: Set<String> = [
        "agentPresetSelected", "backgroundWork", "computerUseUpdated", "planUsageUpdated",
    ]

    /// Decodes a wire event. Payload shapes that fail to decode degrade to
    /// `.unknown` rather than throwing, so one malformed event cannot poison
    /// the stream.
    public init(wire: WireDriverEvent) {
        do {
            self = try Self.decode(wire: wire)
        } catch {
            self = .unknown(kind: wire.kind)
        }
    }

    private static func decode(wire: WireDriverEvent) throws -> DriverEvent {
        let payload = wire.payload
        switch wire.kind {
        case "connected":
            return .connected(providerCursor: payload.isNull ? nil : payload)
        case "autoTitleUpdated":
            return .autoTitleUpdated(payload.stringValue)
        case "availableCommands":
            return .availableCommands(try payload.decode(as: [ReportedCommand].self))
        case "turnStarted":
            return .turnStarted
        case "textDelta":
            return .textDelta(payload.stringValue ?? "")
        case "reasoningDelta":
            return .reasoningDelta(payload.stringValue ?? "")
        case "activity":
            return .activity(
                id: payload["id"]?.stringValue,
                kind: ActivityKind(rawValue: payload["kind"]?.stringValue ?? "") ?? .unknown,
                title: payload["title"]?.stringValue ?? "",
                detail: payload["detail"]?.stringValue,
                complete: payload["complete"]?.boolValue ?? false
            )
        case "richActivity":
            return .richActivity(try payload.decode(as: ActivityItem.self))
        case "permission":
            return .permission(
                requestId: payload["requestId"]?.stringValue ?? "",
                title: payload["title"]?.stringValue ?? "",
                detail: payload["detail"]?.stringValue ?? "",
                options: try (payload["options"] ?? .array([])).decode(as: [PermissionOption].self)
            )
        case "userInputRequested":
            return .userInputRequested(
                requestId: payload["requestId"]?.stringValue ?? "",
                questions: try (payload["questions"] ?? .array([])).decode(as: [UserInputQuestion].self)
            )
        case "steerAccepted":
            return .steerAccepted(message: payload["message"]?.stringValue ?? "")
        case "steerRejected":
            return .steerRejected(
                message: payload["message"]?.stringValue ?? "",
                reason: payload["reason"]?.stringValue ?? ""
            )
        case "usageUpdated":
            return .usageUpdated(
                contextTokens: payload["contextTokens"]?.intValue.map(UInt64.init),
                contextWindow: payload["contextWindow"]?.intValue.map(UInt64.init)
            )
        case "turnFinished":
            return .turnFinished(
                success: payload["success"]?.boolValue ?? false,
                summary: payload["summary"]?.stringValue
            )
        case "error":
            return .error(payload.stringValue ?? "unknown provider error")
        case "processExited":
            return .processExited
        case let kind where ignoredKinds.contains(kind):
            return .ignored(kind: kind)
        case let kind:
            return .unknown(kind: kind)
        }
    }
}
