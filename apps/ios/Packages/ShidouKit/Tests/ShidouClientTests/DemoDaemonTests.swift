import XCTest

@testable import ShidouClient

/// The Demo Daemon is an ordinary Saved Daemon with one flag set, which is
/// the whole point: connecting, candidate failover, last-good persistence and
/// the Grace Window never learn it exists. What these cover is the flag —
/// where it comes from, that it survives storage, and the three behaviours
/// that branch off it.
final class DemoDaemonTests: XCTestCase {
    private func candidates(_ addresses: String...) -> [CandidateAddress] {
        addresses.compactMap { try? CandidateAddress($0) }
    }

    func testTheDemoIsASavedDaemonCarryingTheFlag() {
        let demo = DemoDaemon.saved()
        XCTAssertTrue(demo.isDemo)
        XCTAssertEqual(demo.id, DemoDaemon.id)
        XCTAssertFalse(demo.addresses.isEmpty, "the demo has to be reachable somewhere")
        XCTAssertEqual(
            demo.endpoints(token: DemoDaemon.token).count,
            demo.addresses.count,
            "the baked-in token turns every candidate into an endpoint"
        )
    }

    /// The published host is what a reviewer and a released build reach. A
    /// development candidate may lead it, but it can never be the only one.
    func testTheDemoAlwaysOffersThePublishedHost() {
        XCTAssertTrue(
            DemoDaemon.saved().addresses.contains { $0.host == "demo.shidou.dev" },
            "release builds have nothing else to connect to"
        )
    }

    /// Every demo candidate is either TLS or loopback, so the public token
    /// never crosses a readable wire even before the flag suppresses the
    /// warning.
    func testTheDemoCarriesNoInsecureCandidate() {
        XCTAssertFalse(DemoDaemon.saved().hasInsecureCandidate)
    }

    func testTheFlagSurvivesAStorageRoundTrip() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "shidou-tests-\(UUID().uuidString)"))
        let store = SavedDaemonStore(defaults: defaults)
        store.replace(with: DemoDaemon.saved())
        XCTAssertEqual(store.current()?.isDemo, true)
    }

    /// Saved Daemons written before the flag existed are real Macs, and a
    /// decode that guessed otherwise would drop a paired user into the demo.
    func testDaemonsStoredBeforeTheFlagDecodeAsRealMacs() throws {
        let stored = """
            [{"id":"daemon-1","addresses":["192.168.1.20:34123"],"pairedAt":0}]
            """
        let daemons = try JSONDecoder().decode([SavedDaemon].self, from: Data(stored.utf8))
        XCTAssertEqual(daemons.first?.isDemo, false)
    }

    /// The list-of-one does the eviction; there is no separate demo slot to
    /// clean up.
    func testPairingARealMacEvictsTheDemo() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "shidou-tests-\(UUID().uuidString)"))
        let store = SavedDaemonStore(defaults: defaults)
        store.replace(with: DemoDaemon.saved())

        store.replace(with: SavedDaemon(id: "daemon-1", addresses: candidates("192.168.1.20:34123")))

        XCTAssertEqual(store.load().map(\.id), ["daemon-1"])
        XCTAssertEqual(store.current()?.isDemo, false)
    }

    /// A rejected demo token is not something the user can fix by typing a
    /// new one — it is baked into the build — so the re-pair screen would be
    /// a dead end. Real daemons still route there.
    func testOnlyARealDaemonRoutesToRepair() {
        XCTAssertFalse(DemoDaemon.saved().allowsTokenRepair)
        XCTAssertTrue(SavedDaemon(id: "d", addresses: candidates("h:1")).allowsTokenRepair)
    }

    /// The cleartext warning is about the user's own token on their own
    /// network. The demo's token is published on purpose, so warning about it
    /// would teach the wrong lesson at the worst moment.
    func testOnlyARealDaemonWarnsAboutCleartext() {
        var demo = DemoDaemon.saved()
        demo.addresses = candidates("198.51.100.7:8787")
        XCTAssertFalse(demo.warnsAboutInsecureTransport)

        let real = SavedDaemon(id: "d", addresses: candidates("198.51.100.7:34123"))
        XCTAssertTrue(real.warnsAboutInsecureTransport)
    }
}

/// The demo's token never reaches the Keychain: it is a constant in the
/// binary, and the store in front of the Keychain is where that stops.
final class DemoTokenStoreTests: XCTestCase {
    func testAnswersTheDemoWithoutTouchingTheKeychain() {
        let wrapped = InMemoryTokenStore()
        let store = DemoTokenStore(wrapping: wrapped)
        XCTAssertEqual(store.token(for: DemoDaemon.id), DemoDaemon.token)
        XCTAssertNil(wrapped.token(for: DemoDaemon.id), "nothing was written to reach that answer")
    }

    func testWritesAndDeletesForTheDemoAreNoOps() throws {
        let wrapped = InMemoryTokenStore()
        let store = DemoTokenStore(wrapping: wrapped)
        try store.setToken("something-else", for: DemoDaemon.id)
        try store.removeToken(for: DemoDaemon.id)
        XCTAssertNil(wrapped.token(for: DemoDaemon.id))
        XCTAssertEqual(store.token(for: DemoDaemon.id), DemoDaemon.token)
    }

    func testEveryOtherDaemonGoesToTheWrappedStore() throws {
        let wrapped = InMemoryTokenStore()
        let store = DemoTokenStore(wrapping: wrapped)
        try store.setToken("t0ken", for: "daemon-1")
        XCTAssertEqual(wrapped.token(for: "daemon-1"), "t0ken")
        XCTAssertEqual(store.token(for: "daemon-1"), "t0ken")

        try store.removeToken(for: "daemon-1")
        XCTAssertNil(store.token(for: "daemon-1"))
    }
}
