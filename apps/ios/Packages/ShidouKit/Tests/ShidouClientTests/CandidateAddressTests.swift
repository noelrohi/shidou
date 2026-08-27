import XCTest

@testable import ShidouClient

final class CandidateAddressTests: XCTestCase {
    func testNormalization() throws {
        XCTAssertEqual(
            try CandidateAddress("mac.local:34123").url.absoluteString,
            "ws://mac.local:34123/v1"
        )
        XCTAssertEqual(
            try CandidateAddress("ws://10.0.0.5:34123/other?x=1#y").url.absoluteString,
            "ws://10.0.0.5:34123/v1"
        )
        XCTAssertEqual(
            try CandidateAddress("https://tunnel.example.com").url.absoluteString,
            "wss://tunnel.example.com/v1"
        )
        XCTAssertEqual(
            try CandidateAddress("http://127.0.0.1:9000").url.absoluteString,
            "ws://127.0.0.1:9000/v1"
        )
    }

    /// The address as offered survives normalization: it is what settings
    /// shows, what is persisted, and what `lastGoodAddress` is matched on.
    func testKeepsTheAddressAsOffered() throws {
        XCTAssertEqual(try CandidateAddress("  mac.local:34123 ").raw, "mac.local:34123")
    }

    func testRejectsInvalidAddresses() {
        XCTAssertThrowsError(try CandidateAddress(""))
        XCTAssertThrowsError(try CandidateAddress("ftp://host"))
        XCTAssertThrowsError(try CandidateAddress("ws://user:pass@host:1"))
    }

    func testSecurityFlags() throws {
        XCTAssertFalse(try CandidateAddress("127.0.0.1:34123").isInsecureRemote)
        XCTAssertTrue(try CandidateAddress("192.168.1.20:34123").isInsecureRemote)
        XCTAssertFalse(try CandidateAddress("wss://tunnel.example.com").isInsecureRemote)
    }

    /// Tailnet traffic is WireGuard-encrypted below the socket, so a cleartext
    /// `ws://` token there never crosses a wire an attacker can read.
    func testTailscaleIsTrustedTransport() throws {
        for address in [
            "100.64.0.1:34123", "100.90.1.2:34123", "100.127.255.254:34123", "mac.ts.net:34123",
        ] {
            let candidate = try CandidateAddress(address)
            XCTAssertTrue(candidate.isTailscale, "\(address) is a tailnet address")
            XCTAssertTrue(candidate.isTrustedTransport)
            XCTAssertFalse(candidate.isInsecureRemote, "\(address) must not warn")
        }
    }

    func testAddressesOutsideTheCGNATRangeAreNotTailscale() throws {
        for address in [
            "100.63.255.255:34123", "100.128.0.1:34123", "10.0.0.5:34123",
            "notts.net.example.com:1",
        ] {
            let candidate = try CandidateAddress(address)
            XCTAssertFalse(candidate.isTailscale, "\(address) is not a tailnet address")
            XCTAssertTrue(candidate.isInsecureRemote, "\(address) is cleartext over an untrusted path")
        }
    }

    /// Local Network permission is what iOS gates the same-subnet cases
    /// behind, and nothing else. A public hostname that fails does so for its
    /// own reasons, and must not raise a hint pointing at Settings.
    func testOnlySameNetworkAddressesCountAsLocalNetwork() throws {
        for address in [
            "mac.local:34123", "192.168.1.20:34123", "10.0.0.5:34123", "172.16.4.4:34123",
            "172.31.0.1:34123", "169.254.10.10:34123",
        ] {
            XCTAssertTrue(try CandidateAddress(address).isLocalNetwork, "\(address) is on the LAN")
        }
        for address in [
            "127.0.0.1:34123", "100.90.1.2:34123", "mac.ts.net:34123",
            "daemon.example.com:34123", "172.32.0.1:34123", "8.8.8.8:34123",
        ] {
            XCTAssertFalse(
                try CandidateAddress(address).isLocalNetwork,
                "\(address) never raises the Local Network prompt"
            )
        }
    }

    /// Persisted as the bare string, so the stored shape is a list of
    /// addresses rather than a nest of objects.
    func testEncodesAsThePlainAddress() throws {
        let encoded = try JSONEncoder().encode([CandidateAddress("mac.local:34123")])
        XCTAssertEqual(String(decoding: encoded, as: UTF8.self), "[\"mac.local:34123\"]")
        XCTAssertEqual(
            try JSONDecoder().decode([CandidateAddress].self, from: encoded).map(\.raw),
            ["mac.local:34123"]
        )
    }
}
