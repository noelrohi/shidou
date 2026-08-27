import Foundation

/// The public fixture daemon behind "Try the demo".
///
/// It is a real daemon at a real address speaking the real protocol, so the
/// phone reaches it as an ordinary Saved Daemon with `isDemo` set. Nothing in
/// the connection layer branches on that flag — only the three places listed
/// on `SavedDaemon` do.
public enum DemoDaemon {
    /// Stable and app-minted: the Demo Daemon never renders a pairing code,
    /// so there is no daemon-supplied id to adopt. It keys the same
    /// list-of-one slot every other Saved Daemon uses, which is what makes
    /// pairing a real Mac evict the demo for free.
    public static let id = "dev.shidou.demo"

    /// The Demo Daemon's token, baked into the app instead of the Keychain.
    ///
    /// It is therefore **public** — anyone can read it out of the binary, and
    /// that is the point: "Try the demo" is one tap with nothing to type.
    /// This is safe only because the backend it opens has no side effects. It
    /// executes nothing, holds no credentials, and can spend no money, so the
    /// token grants bandwidth and nothing else (`crates/shidou-demo`, which
    /// carries the matching `DEFAULT_TOKEN`). Never bake in a token for
    /// `shidou-daemon`, where the same constant would be arbitrary execution
    /// on someone's Mac.
    public static let token = "shidou-demo"

    public static let name = "Shidou Demo"

    /// Where `demo.shidou.dev` terminates TLS. Every candidate here is TLS or
    /// loopback, so the published token never crosses a readable wire.
    static let publicAddress = "wss://demo.shidou.dev"

    /// The default bind of a locally run `shidou-demo`, which the simulator
    /// reaches over the host's loopback. It leads in debug builds so a
    /// developer gets their own fixture daemon, and is absent from release
    /// builds entirely.
    static let developmentAddress = "ws://127.0.0.1:8787"

    static var addresses: [String] {
        #if DEBUG
        [developmentAddress, publicAddress]
        #else
        [publicAddress]
        #endif
    }

    /// The Saved Daemon "Try the demo" persists.
    public static func saved() -> SavedDaemon {
        SavedDaemon(
            id: id,
            name: name,
            addresses: addresses.compactMap { try? CandidateAddress($0) },
            isDemo: true
        )
    }
}

/// The store in front of the Keychain that answers the Demo Daemon from the
/// baked-in constant.
///
/// Putting it here rather than at the call sites is what keeps the demo out
/// of the Keychain in every path at once: reads never query securityd, the
/// write at "Try the demo" has nothing to write, and forgetting the demo has
/// nothing to delete. Every other daemon passes straight through.
public struct DemoTokenStore: TokenStore {
    private let wrapped: any TokenStore

    public init(wrapping wrapped: any TokenStore = KeychainTokenStore()) {
        self.wrapped = wrapped
    }

    public func token(for daemonId: String) -> String? {
        daemonId == DemoDaemon.id ? DemoDaemon.token : wrapped.token(for: daemonId)
    }

    public func setToken(_ token: String, for daemonId: String) throws {
        guard daemonId != DemoDaemon.id else { return }
        try wrapped.setToken(token, for: daemonId)
    }

    public func removeToken(for daemonId: String) throws {
        guard daemonId != DemoDaemon.id else { return }
        try wrapped.removeToken(for: daemonId)
    }
}
