import Foundation
import ShidouProtocol

/// One address a daemon may answer at, classified once when it is built.
///
/// A Saved Daemon holds several of these and the phone walks them in order.
/// Three questions get asked of every candidate — is the token readable on
/// this path, will iOS demand Local Network permission to reach it, is it the
/// one that last worked — and each of them is a parse of the address. Parsing
/// once and carrying the answers is what keeps that work out of a view body.
public struct CandidateAddress: Hashable, Sendable {
    /// The address exactly as it was offered: what the pairing payload
    /// carried, what settings shows, and what is persisted.
    public let raw: String
    /// The normalized `ws(s)://host/v1` URL `raw` resolves to.
    public let url: URL

    public init(_ raw: String) throws {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        self.url = try Self.normalize(address: trimmed)
        self.raw = trimmed
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
        guard components.user == nil, components.password == nil,
              components.host?.isEmpty == false
        else {
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

    public var host: String { url.host?.lowercased() ?? "" }

    public var isLoopback: Bool {
        host == "localhost" || host == "127.0.0.1" || host == "::1" || host == "[::1]"
    }

    /// A tailnet address: an IP in the `100.64.0.0/10` CGNAT range Tailscale
    /// assigns, or a MagicDNS name under `*.ts.net`.
    public var isTailscale: Bool {
        if host == "ts.net" || host.hasSuffix(".ts.net") { return true }
        guard let octets = Self.ipv4Octets(host) else { return false }
        // 100.64.0.0/10 — the second octet runs 64...127.
        return octets[0] == 100 && (64...127).contains(octets[1])
    }

    /// The path is encrypted below the WebSocket, so a cleartext `ws://`
    /// token never leaves an attacker-readable wire: TLS, loopback, or a
    /// tailnet (WireGuard end to end).
    public var isTrustedTransport: Bool {
        url.scheme == "wss" || isLoopback || isTailscale
    }

    /// Cleartext token over an untrusted path — worth a UI warning.
    public var isInsecureRemote: Bool {
        url.scheme == "ws" && !isTrustedTransport
    }

    /// Reaching this address means talking to a device on the same physical
    /// network, which is exactly what iOS gates behind Local Network
    /// permission: an mDNS `.local` name, or an RFC 1918 or link-local
    /// literal. A public hostname is not local, so a daemon behind a DNS
    /// name never raises the permission hint on a failure it cannot explain.
    public var isLocalNetwork: Bool {
        if isLoopback || isTailscale { return false }
        if host == "local" || host.hasSuffix(".local") { return true }
        guard let octets = Self.ipv4Octets(host) else { return false }
        switch (octets[0], octets[1]) {
        case (10, _), (192, 168), (169, 254):
            return true
        case (172, 16...31):
            return true
        default:
            return false
        }
    }

    public func endpoint(token: String) -> DaemonEndpoint {
        DaemonEndpoint(candidate: self, token: token)
    }

    /// The four octets of a dotted-quad host, or `nil` for anything else —
    /// a name, an IPv6 literal, a partial address.
    static func ipv4Octets(_ host: String) -> [UInt8]? {
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        let octets = parts.compactMap { UInt8($0) }
        return octets.count == 4 ? octets : nil
    }
}

extension CandidateAddress: Codable {
    /// Persisted as the plain string it came from, so a Saved Daemon on disk
    /// stays a list of addresses that either half of the app can read.
    public init(from decoder: any Decoder) throws {
        try self.init(decoder.singleValueContainer().decode(String.self))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(raw)
    }
}

extension CandidateAddress: CustomStringConvertible {
    public var description: String { raw }
}
