import Foundation

/// A daemon the phone has paired with. v1 keeps exactly one, but it persists
/// as a list-of-one keyed by daemon id so multi-daemon is later a UI change
/// rather than a storage migration.
///
/// Everything here is ordinary app storage — none of it is a secret. The
/// token lives in the Keychain under `daemonId` (see `TokenStore`).
public struct SavedDaemon: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    /// The Mac's display name from the pairing payload, when it sent one.
    public var name: String?
    /// Candidate addresses in the order the daemon offered them.
    public var addresses: [CandidateAddress]
    /// The candidate that last completed a handshake; reconnect tries it
    /// first, so a phone that settled on the tailnet does not re-walk LAN
    /// addresses that will only time out.
    public var lastGoodAddress: CandidateAddress?
    /// Set when the daemon rejects the token — the addresses stay, the app
    /// shows the re-pair screen instead of retrying.
    public var tokenIsInvalid: Bool
    /// The one-time cleartext warning has been shown for this daemon. The
    /// settings badge is derived from the addresses and never suppressed.
    public var acknowledgedInsecureWarning: Bool
    public var pairedAt: Date

    public init(
        id: String,
        name: String? = nil,
        addresses: [CandidateAddress],
        lastGoodAddress: CandidateAddress? = nil,
        tokenIsInvalid: Bool = false,
        acknowledgedInsecureWarning: Bool = false,
        pairedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.addresses = addresses
        self.lastGoodAddress = lastGoodAddress
        self.tokenIsInvalid = tokenIsInvalid
        self.acknowledgedInsecureWarning = acknowledgedInsecureWarning
        self.pairedAt = pairedAt
    }

    public init(payload: PairingPayload) {
        self.init(id: payload.daemonId, name: payload.name, addresses: payload.addresses)
    }

    /// Decoded leniently in the addresses: one entry that no longer parses
    /// must cost that candidate, not the whole Saved Daemon and the paired
    /// state that goes with it.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decodeIfPresent(String.self, forKey: .name)
        addresses = try container.decode([String].self, forKey: .addresses)
            .compactMap { try? CandidateAddress($0) }
        lastGoodAddress = try container.decodeIfPresent(String.self, forKey: .lastGoodAddress)
            .flatMap { try? CandidateAddress($0) }
        tokenIsInvalid = try container.decodeIfPresent(Bool.self, forKey: .tokenIsInvalid) ?? false
        acknowledgedInsecureWarning =
            try container.decodeIfPresent(Bool.self, forKey: .acknowledgedInsecureWarning) ?? false
        pairedAt = try container.decodeIfPresent(Date.self, forKey: .pairedAt) ?? Date()
    }

    /// Candidates in connect order: last-good first, then the rest in the
    /// order the daemon offered them.
    public func orderedAddresses() -> [CandidateAddress] {
        guard let lastGoodAddress, addresses.contains(lastGoodAddress) else { return addresses }
        return [lastGoodAddress] + addresses.filter { $0 != lastGoodAddress }
    }

    public func endpoints(token: String) -> [DaemonEndpoint] {
        orderedAddresses().map { $0.endpoint(token: token) }
    }

    /// True when any candidate would carry the token in the clear over an
    /// untrusted path. Tailnet and loopback addresses do not count.
    public var hasInsecureCandidate: Bool {
        addresses.contains(where: \.isInsecureRemote)
    }

    /// True when at least one candidate is on the same physical network,
    /// which is what makes iOS ask for Local Network permission. A tailnet or
    /// public-hostname daemon never triggers the prompt, so the
    /// denied-permission hint stays hidden.
    public var hasLocalNetworkCandidate: Bool {
        addresses.contains(where: \.isLocalNetwork)
    }
}

/// The saved-daemon list. Backed by `UserDefaults` because it is small,
/// non-secret, and read once at launch.
public final class SavedDaemonStore: @unchecked Sendable {
    public static let defaultsKey = "dev.shidou.ios.saved-daemons"

    private let defaults: UserDefaults
    private let key: String

    public init(defaults: UserDefaults = .standard, key: String = SavedDaemonStore.defaultsKey) {
        self.defaults = defaults
        self.key = key
    }

    public func load() -> [SavedDaemon] {
        guard let data = defaults.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([SavedDaemon].self, from: data)) ?? []
    }

    public func save(_ daemons: [SavedDaemon]) {
        guard let data = try? JSONEncoder().encode(daemons) else { return }
        defaults.set(data, forKey: key)
    }

    /// v1's single daemon.
    public func current() -> SavedDaemon? { load().first }

    public func replace(with daemon: SavedDaemon) { save([daemon]) }

    public func update(_ transform: (inout SavedDaemon) -> Void) {
        var daemons = load()
        guard !daemons.isEmpty else { return }
        transform(&daemons[0])
        save(daemons)
    }

    public func removeAll() { defaults.removeObject(forKey: key) }
}
