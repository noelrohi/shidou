import XCTest

@testable import ShidouClient

final class PairingPayloadTests: XCTestCase {
    func testRoundTripsThroughItsURL() throws {
        let payload = try PairingPayload(
            daemonId: "6E2F5C64-0000-4000-8000-000000000001",
            name: "Rohi's MacBook Pro",
            addresses: ["192.168.1.20:34123", "rohis-macbook-pro.local:34123", "100.101.102.103:34123"],
            token: "s3cr3t token/with+chars"
        )
        let parsed = try PairingPayload(url: payload.url)
        XCTAssertEqual(parsed, payload)
        XCTAssertEqual(parsed.addresses, payload.addresses, "candidate order is part of the payload")
    }

    func testParsesADesktopRenderedURL() throws {
        let url = URL(
            string: "shidou://pair?v=1&id=abc&name=Studio&addr=192.168.1.20:34123&addr=100.90.1.2:34123&token=t0ken"
        )!
        let payload = try PairingPayload(url: url)
        XCTAssertEqual(payload.daemonId, "abc")
        XCTAssertEqual(payload.name, "Studio")
        XCTAssertEqual(payload.addresses.map(\.raw), ["192.168.1.20:34123", "100.90.1.2:34123"])
        XCTAssertEqual(payload.token, "t0ken")
        XCTAssertEqual(
            payload.endpoints().map(\.url.absoluteString),
            ["ws://192.168.1.20:34123/v1", "ws://100.90.1.2:34123/v1"]
        )
    }

    /// The exact string the desktop emits, byte for byte, from
    /// `pairing_url_lists_addresses_in_order` in `src/pairing.rs`. The two
    /// halves of pairing are written in different languages against the same
    /// URL, so one of them changing its encoding is the failure this catches.
    func testParsesTheDesktopEncodingExactly() throws {
        let url = URL(
            string: "shidou://pair?v=1&id=daemon-1&name=studio&addr=192.168.1.20%3A34123&addr=100.90.1.2%3A34123&token=abc123"
        )!
        let payload = try PairingPayload(url: url)
        XCTAssertEqual(payload.daemonId, "daemon-1")
        XCTAssertEqual(payload.name, "studio")
        XCTAssertEqual(payload.addresses.map(\.raw), ["192.168.1.20:34123", "100.90.1.2:34123"])
        XCTAssertEqual(payload.token, "abc123")
    }

    /// Hostnames reach the payload as typed, and a Mac name carries spaces
    /// and punctuation more often than not.
    func testParsesANameWithSpacesAndPunctuation() throws {
        let url = URL(
            string: "shidou://pair?v=1&id=d&name=Noels-MacBook-Pro%20(tailnet)&addr=100.92.14.103%3A34123&token=t"
        )!
        let payload = try PairingPayload(url: url)
        XCTAssertEqual(payload.name, "Noels-MacBook-Pro (tailnet)")
        XCTAssertEqual(payload.addresses.map(\.raw), ["100.92.14.103:34123"])
    }

    func testRejectsForeignAndMalformedURLs() {
        func error(_ string: String) -> PairingError? {
            guard let url = URL(string: string) else { return nil }
            do {
                _ = try PairingPayload(url: url)
                return nil
            } catch let failure as PairingError {
                return failure
            } catch {
                return nil
            }
        }
        XCTAssertEqual(error("https://example.com/pair?v=1"), .notAPairingURL)
        XCTAssertEqual(error("shidou://open?v=1&id=a&addr=h:1&token=t"), .notAPairingURL)
        XCTAssertEqual(error("shidou://pair?id=a&addr=h:1&token=t"), .unsupportedVersion(nil))
        XCTAssertEqual(error("shidou://pair?v=2&id=a&addr=h:1&token=t"), .unsupportedVersion(2))
        XCTAssertEqual(error("shidou://pair?v=1&id=a&addr=h:1"), .missingToken)
        XCTAssertEqual(error("shidou://pair?v=1&addr=h:1&token=t"), .missingDaemonId)
        XCTAssertEqual(error("shidou://pair?v=1&id=a&token=t"), .noAddresses)
    }

    func testRejectsAnAddressThatCannotNormalize() {
        XCTAssertThrowsError(
            try PairingPayload(daemonId: "a", name: nil, addresses: ["ftp://nope"], token: "t")
        )
    }

    func testIgnoresUnknownQueryItems() throws {
        let url = URL(string: "shidou://pair?v=1&id=a&addr=h:1&token=t&future=whatever")!
        XCTAssertEqual(try PairingPayload(url: url).addresses.map(\.raw), ["h:1"])
    }
}

final class SavedDaemonTests: XCTestCase {
    private func candidates(_ addresses: String...) -> [CandidateAddress] {
        addresses.compactMap { try? CandidateAddress($0) }
    }

    private func daemon(lastGood: String? = nil) -> SavedDaemon {
        SavedDaemon(
            id: "daemon-1",
            name: "Studio",
            addresses: candidates("192.168.1.20:34123", "studio.local:34123", "100.90.1.2:34123"),
            lastGoodAddress: lastGood.flatMap { try? CandidateAddress($0) }
        )
    }

    func testLastGoodAddressLeadsTheOrder() {
        XCTAssertEqual(
            daemon(lastGood: "100.90.1.2:34123").orderedAddresses().map(\.raw),
            ["100.90.1.2:34123", "192.168.1.20:34123", "studio.local:34123"]
        )
    }

    func testUnknownLastGoodAddressLeavesTheOfferedOrder() {
        let stale = daemon(lastGood: "10.0.0.9:34123")
        XCTAssertEqual(stale.orderedAddresses(), stale.addresses)
    }

    func testClassifiesCandidatesForTheWarningAndTheLocalNetworkHint() {
        XCTAssertTrue(daemon().hasInsecureCandidate, "a LAN ws:// candidate is cleartext")
        XCTAssertTrue(daemon().hasLocalNetworkCandidate)

        let tailnetOnly = SavedDaemon(
            id: "d", addresses: candidates("100.90.1.2:34123", "mac.ts.net:34123")
        )
        XCTAssertFalse(tailnetOnly.hasInsecureCandidate, "tailnet traffic is encrypted below the socket")
        XCTAssertFalse(
            tailnetOnly.hasLocalNetworkCandidate,
            "a tailnet address goes over the VPN interface, so iOS never prompts"
        )
    }

    /// One address that no longer parses costs that candidate, not the whole
    /// pairing: the token, the id, and the addresses that still work stay.
    func testDecodingKeepsTheDaemonWhenOneAddressIsUnreadable() throws {
        let stored = """
            [{"id":"daemon-1","addresses":["192.168.1.20:34123","ftp://nope"],\
            "tokenIsInvalid":true,"acknowledgedInsecureWarning":false,\
            "pairedAt":0}]
            """.replacingOccurrences(of: "\\\n", with: "")
        let daemons = try JSONDecoder().decode(
            [SavedDaemon].self, from: Data(stored.utf8)
        )
        XCTAssertEqual(daemons.first?.addresses.map(\.raw), ["192.168.1.20:34123"])
        XCTAssertEqual(daemons.first?.tokenIsInvalid, true)
    }

    func testStoreKeepsExactlyOneDaemonAsAList() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "shidou-tests-\(UUID().uuidString)"))
        let store = SavedDaemonStore(defaults: defaults)
        XCTAssertNil(store.current())

        store.replace(with: daemon())
        XCTAssertEqual(store.load().count, 1)
        XCTAssertEqual(store.current()?.id, "daemon-1")

        store.update { $0.lastGoodAddress = try? CandidateAddress("studio.local:34123") }
        XCTAssertEqual(store.current()?.lastGoodAddress?.raw, "studio.local:34123")

        store.replace(with: SavedDaemon(id: "daemon-2", addresses: candidates("h:1")))
        XCTAssertEqual(store.load().map(\.id), ["daemon-2"], "pairing replaces rather than appends")

        store.removeAll()
        XCTAssertNil(store.current())
    }
}
