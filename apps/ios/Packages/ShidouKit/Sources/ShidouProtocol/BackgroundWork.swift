import Foundation

// Mirrors the background-work half of `crates/shidou-protocol/src/model.rs`.
// Unlike most of that module these types *do* carry `rename_all = "camelCase"`,
// so their wire fields are camelCase. `BackgroundWorkEvent` is internally
// tagged, and its two newtype variants therefore flatten the wrapped struct's
// fields alongside `type`.

public enum BackgroundWorkKind: String, WireStringEnum {
    case process, monitor, subagent
    case unknown

    public static var unknownCase: Self { .unknown }
}

public enum BackgroundWorkStatus: String, WireStringEnum {
    case starting, running, monitoring, stopping, completed, failed, stopped, lost
    case unknown

    public static var unknownCase: Self { .unknown }

    /// Mirrors `BackgroundWorkStatus::is_live`.
    public var isLive: Bool {
        switch self {
        case .starting, .running, .monitoring, .stopping: return true
        default: return false
        }
    }

    /// Mirrors `BackgroundWorkStatus::is_stoppable`. An item that says it can
    /// be stopped but is no longer in one of these states is already over.
    public var isStoppable: Bool {
        switch self {
        case .starting, .running, .monitoring: return true
        default: return false
        }
    }
}

public struct BackgroundWorkKey: Codable, Hashable, Sendable {
    public var kind: BackgroundWorkKind
    public var providerId: String

    public init(kind: BackgroundWorkKind, providerId: String) {
        self.kind = kind
        self.providerId = providerId
    }
}

public struct BackgroundWorkItem: Codable, Hashable, Sendable, Identifiable {
    public var key: BackgroundWorkKey
    public var title: String
    public var detail: String?
    public var command: String?
    public var cwd: String?
    public var output: String?
    public var outputTruncated: Bool
    public var startedAtMs: UInt64
    public var updatedAtMs: UInt64
    public var durationMs: UInt64?
    public var exitCode: Int?
    /// Whether the provider considers this detached from the foreground turn.
    public var background: Bool
    public var canStop: Bool
    /// Provider-native identifier used for an authoritative stop request.
    public var controlId: String?
    /// Transcript activity that created this work, when the provider exposes it.
    public var originActivityId: String?
    public var role: String?
    public var model: String?
    public var parentId: String?
    public var status: BackgroundWorkStatus

    public var id: BackgroundWorkKey { key }

    public init(
        key: BackgroundWorkKey,
        title: String,
        detail: String? = nil,
        command: String? = nil,
        cwd: String? = nil,
        output: String? = nil,
        outputTruncated: Bool = false,
        startedAtMs: UInt64 = 0,
        updatedAtMs: UInt64 = 0,
        durationMs: UInt64? = nil,
        exitCode: Int? = nil,
        background: Bool = false,
        canStop: Bool = false,
        controlId: String? = nil,
        originActivityId: String? = nil,
        role: String? = nil,
        model: String? = nil,
        parentId: String? = nil,
        status: BackgroundWorkStatus
    ) {
        self.key = key
        self.title = title
        self.detail = detail
        self.command = command
        self.cwd = cwd
        self.output = output
        self.outputTruncated = outputTruncated
        self.startedAtMs = startedAtMs
        self.updatedAtMs = updatedAtMs
        self.durationMs = durationMs
        self.exitCode = exitCode
        self.background = background
        self.canStop = canStop
        self.controlId = controlId
        self.originActivityId = originActivityId
        self.role = role
        self.model = model
        self.parentId = parentId
        self.status = status
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        key = try container.decode(BackgroundWorkKey.self, forKey: .key)
        title = try container.decode(String.self, forKey: .title)
        detail = try container.decodeIfPresent(String.self, forKey: .detail)
        command = try container.decodeIfPresent(String.self, forKey: .command)
        cwd = try container.decodeIfPresent(String.self, forKey: .cwd)
        output = try container.decodeIfPresent(String.self, forKey: .output)
        outputTruncated = try container.decodeIfPresent(Bool.self, forKey: .outputTruncated) ?? false
        startedAtMs = try container.decodeIfPresent(UInt64.self, forKey: .startedAtMs) ?? 0
        updatedAtMs = try container.decodeIfPresent(UInt64.self, forKey: .updatedAtMs) ?? 0
        durationMs = try container.decodeIfPresent(UInt64.self, forKey: .durationMs)
        exitCode = try container.decodeIfPresent(Int.self, forKey: .exitCode)
        background = try container.decodeIfPresent(Bool.self, forKey: .background) ?? false
        canStop = try container.decodeIfPresent(Bool.self, forKey: .canStop) ?? false
        controlId = try container.decodeIfPresent(String.self, forKey: .controlId)
        originActivityId = try container.decodeIfPresent(String.self, forKey: .originActivityId)
        role = try container.decodeIfPresent(String.self, forKey: .role)
        model = try container.decodeIfPresent(String.self, forKey: .model)
        parentId = try container.decodeIfPresent(String.self, forKey: .parentId)
        status = try container.decode(BackgroundWorkStatus.self, forKey: .status)
    }
}

/// Internally tagged, so `upsert` and `stopRequested` carry the wrapped
/// struct's own fields beside `type` rather than nesting them.
public enum BackgroundWorkEvent: Sendable {
    case upsert(BackgroundWorkItem)
    case outputDelta(key: BackgroundWorkKey, delta: String)
    /// Authoritative snapshot of the provider's detached terminal registry.
    case reconcileProcesses([BackgroundWorkItem])
    /// Authoritative snapshot of all provider work still live.
    case reconcileLive([BackgroundWorkItem])
    case stopRequested(BackgroundWorkKey)
    case stopFailed(key: BackgroundWorkKey, message: String)
    case unknown(type: String)
}

extension BackgroundWorkEvent: Decodable {
    private enum CodingKeys: String, CodingKey {
        case type, key, delta, items, message
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(String.self, forKey: .type) {
        case "upsert":
            self = .upsert(try BackgroundWorkItem(from: decoder))
        case "outputDelta":
            self = .outputDelta(
                key: try container.decode(BackgroundWorkKey.self, forKey: .key),
                delta: try container.decode(String.self, forKey: .delta)
            )
        case "reconcileProcesses":
            self = .reconcileProcesses(try container.decode([BackgroundWorkItem].self, forKey: .items))
        case "reconcileLive":
            self = .reconcileLive(try container.decode([BackgroundWorkItem].self, forKey: .items))
        case "stopRequested":
            self = .stopRequested(try BackgroundWorkKey(from: decoder))
        case "stopFailed":
            self = .stopFailed(
                key: try container.decode(BackgroundWorkKey.self, forKey: .key),
                message: try container.decode(String.self, forKey: .message)
            )
        case let type:
            self = .unknown(type: type)
        }
    }
}
