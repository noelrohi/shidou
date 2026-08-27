import Foundation
import ShidouProtocol

/// What a `shidou://pair` URL carries: the daemon's identity, its ordered
/// candidate addresses, and the token.
///
/// The desktop renders this as a QR in its Daemon settings pane; the phone
/// reaches it by camera scan or by tapping the link. Registering the scheme
/// is what makes both work, so the format is versioned from the first build:
/// a future daemon can widen the payload and an older app can say so instead
/// of pairing against a half-understood URL.
///
///     shidou://pair?v=1&id=<uuid>&name=<display>&addr=<a>&addr=<b>&token=<t>
///
/// `addr` repeats in priority order (LAN IP, `.local`, tailnet). Manual entry
/// builds the same payload with a single address and a locally minted id.
public struct PairingPayload: Sendable, Equatable {
    public static let scheme = "shidou"
    public static let host = "pair"
    /// Bumped only when a change would confuse an older parser. Additive
    /// query parameters do not bump it — unknown keys are ignored.
    public static let currentVersion = 1

    public let daemonId: String
    /// The Mac's display name, shown while pairing and in settings.
    public let name: String?
    /// Candidate addresses in the order the daemon offered them. Each one is
    /// validated here, so a payload that parses is a payload that connects.
    public let addresses: [CandidateAddress]
    public let token: String

    public init(daemonId: String, name: String?, addresses: [String], token: String) throws {
        let cleanedId = daemonId.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanedToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanedAddresses = addresses
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !cleanedId.isEmpty else { throw PairingError.missingDaemonId }
        guard !cleanedToken.isEmpty else { throw PairingError.missingToken }
        guard !cleanedAddresses.isEmpty else { throw PairingError.noAddresses }
        self.daemonId = cleanedId
        self.name = name?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
        self.addresses = try cleanedAddresses.map { try CandidateAddress($0) }
        self.token = cleanedToken
    }

    /// Parses a scanned or opened `shidou://pair` URL.
    public init(url: URL) throws {
        guard url.scheme?.lowercased() == Self.scheme else {
            throw PairingError.notAPairingURL
        }
        guard url.host?.lowercased() == Self.host else {
            throw PairingError.notAPairingURL
        }
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let items = components.queryItems
        else {
            throw PairingError.notAPairingURL
        }
        func first(_ name: String) -> String? {
            items.first { $0.name == name }?.value?.nonEmpty
        }
        guard let rawVersion = first("v"), let version = Int(rawVersion) else {
            throw PairingError.unsupportedVersion(nil)
        }
        guard version == Self.currentVersion else {
            throw PairingError.unsupportedVersion(version)
        }
        guard let token = first("token") else { throw PairingError.missingToken }
        guard let daemonId = first("id") else { throw PairingError.missingDaemonId }
        let addresses = items.filter { $0.name == "addr" }.compactMap { $0.value?.nonEmpty }
        try self.init(daemonId: daemonId, name: first("name"), addresses: addresses, token: token)
    }

    public var url: URL {
        var components = URLComponents()
        components.scheme = Self.scheme
        components.host = Self.host
        var items = [
            URLQueryItem(name: "v", value: String(Self.currentVersion)),
            URLQueryItem(name: "id", value: daemonId),
        ]
        if let name { items.append(URLQueryItem(name: "name", value: name)) }
        items.append(contentsOf: addresses.map { URLQueryItem(name: "addr", value: $0.raw) })
        items.append(URLQueryItem(name: "token", value: token))
        components.queryItems = items
        // Every component is either a UUID, a host:port, or a percent-encoded
        // string, so the URL always composes.
        guard let url = components.url else {
            preconditionFailure("pairing payload failed to compose a URL")
        }
        return url
    }

    /// The candidates as connectable endpoints, in offered order.
    public func endpoints() -> [DaemonEndpoint] {
        addresses.map { $0.endpoint(token: token) }
    }
}

public enum PairingError: Error, Equatable, Sendable {
    case notAPairingURL
    /// `nil` when the URL carried no readable version at all.
    case unsupportedVersion(Int?)
    case missingDaemonId
    case missingToken
    case noAddresses
}

extension PairingError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .notAPairingURL:
            return "That code is not a Shidou pairing code"
        case .unsupportedVersion(let version):
            if let version {
                return "This pairing code needs a newer version of Shidou (format \(version))"
            }
            return "That pairing code is missing its format version"
        case .missingDaemonId:
            return "That pairing code is missing the computer's identifier"
        case .missingToken:
            return "That pairing code is missing the daemon token"
        case .noAddresses:
            return "That pairing code carries no address to connect to"
        }
    }
}

extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
