import XCTest

@testable import ShidouClient

final class DaemonEndpointTests: XCTestCase {
    func testNormalization() throws {
        XCTAssertEqual(
            try DaemonEndpoint.normalize(address: "mac.local:34123").absoluteString,
            "ws://mac.local:34123/v1"
        )
        XCTAssertEqual(
            try DaemonEndpoint.normalize(address: "ws://10.0.0.5:34123/other?x=1#y").absoluteString,
            "ws://10.0.0.5:34123/v1"
        )
        XCTAssertEqual(
            try DaemonEndpoint.normalize(address: "https://tunnel.example.com").absoluteString,
            "wss://tunnel.example.com/v1"
        )
        XCTAssertEqual(
            try DaemonEndpoint.normalize(address: "http://127.0.0.1:9000").absoluteString,
            "ws://127.0.0.1:9000/v1"
        )
    }

    func testRejectsInvalidAddresses() {
        XCTAssertThrowsError(try DaemonEndpoint.normalize(address: ""))
        XCTAssertThrowsError(try DaemonEndpoint.normalize(address: "ftp://host"))
        XCTAssertThrowsError(try DaemonEndpoint.normalize(address: "ws://user:pass@host:1"))
    }

    func testSecurityFlags() throws {
        XCTAssertFalse(try DaemonEndpoint(address: "127.0.0.1:34123", token: "t").isInsecureRemote)
        XCTAssertTrue(try DaemonEndpoint(address: "192.168.1.20:34123", token: "t").isInsecureRemote)
        XCTAssertFalse(try DaemonEndpoint(address: "wss://tunnel.example.com", token: "t").isInsecureRemote)
    }
}
