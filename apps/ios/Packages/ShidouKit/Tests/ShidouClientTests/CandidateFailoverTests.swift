import XCTest

@testable import ShidouClient

/// Closed loopback ports refuse instantly, so one round over two of them is a
/// fast, real exercise of the failover walk — no daemon required.
final class CandidateFailoverTests: XCTestCase {
    func testARoundWalksEveryCandidateBeforeBackingOff() async throws {
        let first = try DaemonEndpoint(address: "127.0.0.1:1", token: "t")
        let second = try DaemonEndpoint(address: "127.0.0.1:2", token: "t")
        let supervisor = ConnectionSupervisor(candidates: [first, second])
        let phases = await supervisor.events()
        await supervisor.start()

        var seen: [ConnectionPhase] = []
        for await item in phases {
            guard case .phase(let phase) = item else { continue }
            seen.append(phase)
            if case .backingOff = phase { break }
        }
        await supervisor.stop()

        XCTAssertEqual(
            seen.compactMap(\.endpoint),
            [first, second],
            "both candidates are tried within one attempt"
        )
        guard case .backingOff(_, _, _) = seen.last else {
            return XCTFail("an exhausted round backs off, got \(String(describing: seen.last))")
        }
        let attempts = seen.compactMap { phase -> Int? in
            if case .connecting(let attempt, _) = phase { return attempt }
            return nil
        }
        XCTAssertEqual(attempts, [1, 1], "walking candidates is one attempt, not one per address")
    }

    /// A blackholed address never refuses; it just sits there. Without a
    /// per-candidate deadline the walk inherits URLSession's 60-second
    /// default and the address that would have worked never gets a turn.
    func testAHangingCandidateDoesNotHoldTheWalk() async throws {
        let blackhole = try DaemonEndpoint(address: "10.255.255.1:34123", token: "t")
        let refused = try DaemonEndpoint(address: "127.0.0.1:1", token: "t")
        let supervisor = ConnectionSupervisor(
            candidates: [blackhole, refused],
            candidateTimeout: .milliseconds(300)
        )
        let phases = await supervisor.events()
        let started = ContinuousClock.now
        await supervisor.start()

        var seen: [DaemonEndpoint] = []
        for await item in phases {
            guard case .phase(let phase) = item else { continue }
            if let endpoint = phase.endpoint { seen.append(endpoint) }
            if case .backingOff = phase { break }
        }
        let elapsed = ContinuousClock.now - started
        await supervisor.stop()

        XCTAssertEqual(seen, [blackhole, refused])
        XCTAssertLessThan(
            elapsed, .seconds(5),
            "the walk must be bounded by the candidate timeout, not the URLSession default"
        )
    }

    /// A supervisor that has never connected is starting up; one that has is
    /// reconnecting, and its consumers hold projections that missed whatever
    /// arrived while the socket was down. The attempt counter cannot tell
    /// those apart, because a connection that lived resets it.
    func testTheFirstConnectionIsNotAnnouncedAsAReconnect() async throws {
        let refused = try DaemonEndpoint(address: "127.0.0.1:1", token: "t")
        let supervisor = ConnectionSupervisor(candidates: [refused])
        let events = await supervisor.events()
        await supervisor.start()

        var sawReconnected = false
        for await item in events {
            if case .reconnected = item { sawReconnected = true }
            if case .phase(.backingOff) = item { break }
        }
        await supervisor.stop()
        XCTAssertFalse(sawReconnected, "nothing connected, so nothing reconnected")
    }

    func testSingleEndpointInitStillWorks() async throws {
        let only = try DaemonEndpoint(address: "127.0.0.1:1", token: "t")
        let supervisor = ConnectionSupervisor(endpoint: only)
        let candidates = await supervisor.candidateOrder
        XCTAssertEqual(candidates, [only])
    }
}
