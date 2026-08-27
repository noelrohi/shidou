import Foundation
import ShidouProtocol

/// A candidate address plus the token to present there: everything one
/// connection attempt needs. How the address is classified belongs to
/// `CandidateAddress`, which answers those questions without a token.
public struct DaemonEndpoint: Hashable, Sendable {
    public let candidate: CandidateAddress
    public let token: String

    public init(candidate: CandidateAddress, token: String) {
        self.candidate = candidate
        self.token = token
    }

    public init(address: String, token: String) throws {
        self.init(candidate: try CandidateAddress(address), token: token)
    }

    /// Normalized `ws://` or `wss://` URL with path `/v1`.
    public var url: URL { candidate.url }
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
