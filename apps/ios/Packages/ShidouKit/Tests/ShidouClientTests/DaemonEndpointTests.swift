import XCTest

@testable import ShidouClient

/// Address parsing and classification live in `CandidateAddressTests`; what
/// is left here is the pairing of an address with the token to present there.
final class DaemonEndpointTests: XCTestCase {
    func testCarriesTheNormalizedURLOfItsCandidate() throws {
        let endpoint = try DaemonEndpoint(address: "mac.local:34123", token: "t")
        XCTAssertEqual(endpoint.url.absoluteString, "ws://mac.local:34123/v1")
        XCTAssertEqual(endpoint.candidate.raw, "mac.local:34123")
        XCTAssertEqual(endpoint.token, "t")
    }

    func testRejectsAnAddressItCannotNormalize() {
        XCTAssertThrowsError(try DaemonEndpoint(address: "ftp://host", token: "t"))
    }

    /// The same address with two tokens is two endpoints: the supervisor
    /// promotes and compares them, and a rotated token must not read as the
    /// candidate that already worked.
    func testTokenParticipatesInIdentity() throws {
        let first = try DaemonEndpoint(address: "mac.local:34123", token: "a")
        let second = try DaemonEndpoint(address: "mac.local:34123", token: "b")
        XCTAssertNotEqual(first, second)
        XCTAssertEqual(first.candidate, second.candidate)
    }
}
