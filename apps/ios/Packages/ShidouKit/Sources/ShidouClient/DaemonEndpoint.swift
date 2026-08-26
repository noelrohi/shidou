import Foundation
import ShidouProtocol

public struct DaemonEndpoint: Hashable, Sendable {
    /// Normalized `ws://` or `wss://` URL with path `/v1`.
    public let url: URL
    public let token: String

    public init(address: String, token: String) throws {
        self.url = try Self.normalize(address: address)
        self.token = token
    }

    /// Port of `daemonUrl()` in `packages/shidou-client/src/client.ts` plus
    /// the web client's address validation: bare `host:port` gets a `ws://`
    /// scheme, `http(s)` maps to `ws(s)`, the path is forced to `/v1`, and
    /// URLs carrying credentials are rejected.
    public static func normalize(address: String) throws -> URL {
        let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw ShidouError.invalidAddress(address)
        }
        var candidate = trimmed
        if !candidate.contains("://") {
            candidate = "ws://\(candidate)"
        }
        guard var components = URLComponents(string: candidate) else {
            throw ShidouError.invalidAddress(address)
        }
        switch components.scheme?.lowercased() {
        case "ws", "wss":
            break
        case "http":
            components.scheme = "ws"
        case "https":
            components.scheme = "wss"
        default:
            throw ShidouError.invalidAddress(address)
        }
        guard components.user == nil, components.password == nil, components.host?.isEmpty == false else {
            throw ShidouError.invalidAddress(address)
        }
        components.path = ShidouWire.endpointPath
        components.query = nil
        components.fragment = nil
        guard let url = components.url else {
            throw ShidouError.invalidAddress(address)
        }
        return url
    }

    public var isLoopback: Bool {
        guard let host = url.host?.lowercased() else { return false }
        return host == "localhost" || host == "127.0.0.1" || host == "::1" || host == "[::1]"
    }

    /// Cleartext token over a non-loopback network — worth a UI warning.
    public var isInsecureRemote: Bool {
        url.scheme == "ws" && !isLoopback
    }
}

public enum ShidouError: Error, Sendable {
    case invalidAddress(String)
    case invalidHandshake(String)
    case rejected(message: String)
    case disconnected
    case requestTimeout
    case rpc(message: String)
    case unexpectedResponse(expected: String)
    case shuttingDown
}

extension ShidouError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidAddress(let address):
            return "\"\(address)\" is not a valid daemon address"
        case .invalidHandshake(let detail):
            return "The daemon handshake failed: \(detail)"
        case .rejected(let message):
            return "The daemon rejected the connection: \(message)"
        case .disconnected:
            return "The daemon connection was lost"
        case .requestTimeout:
            return "The daemon did not answer in time"
        case .rpc(let message):
            return message
        case .unexpectedResponse(let expected):
            return "The daemon returned an unexpected response (expected \(expected))"
        case .shuttingDown:
            return "The daemon is shutting down"
        }
    }
}
