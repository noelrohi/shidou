import Foundation
import ShidouProtocol

/// A failure retrying cannot fix. The app routes on the case: a rejected
/// token is the re-pair screen, everything else is a dead end the connection
/// screen explains.
public enum ConnectionFailure: Sendable, Equatable {
    case tokenRejected(String)
    case protocolMismatch(String)
    case invalidAddress(String)

    public var message: String {
        switch self {
        case .tokenRejected(let message), .protocolMismatch(let message),
             .invalidAddress(let message):
            return message
        }
    }
}

public enum ConnectionPhase: Sendable, Equatable {
    case idle
    case connecting(attempt: Int, endpoint: DaemonEndpoint)
    case connected(DaemonHello, endpoint: DaemonEndpoint)
    case backingOff(nextAttempt: Int, delay: Duration, lastError: String)
    case failed(ConnectionFailure)

    /// The endpoint this phase concerns, when it concerns one.
    public var endpoint: DaemonEndpoint? {
        switch self {
        case .connecting(_, let endpoint), .connected(_, let endpoint):
            return endpoint
        case .idle, .backingOff, .failed:
            return nil
        }
    }
}

public enum SupervisedEvent: Sendable {
    case phase(ConnectionPhase)
    case event(SequencedEvent)
    case taskStateChanged(revision: UInt64)
    /// The daemon's journal moved past our cursor for one session runtime
    /// while we were away. Arrives ahead of the tail it could still replay.
    case replayGap(ReplayGap)
    /// A fresh connection completed its handshake. Consumers should re-attach
    /// sessions and refetch task state; replayed events follow on the stream.
    case reconnected(DaemonHello)
    /// A candidate completed a handshake, so it becomes the one reconnect
    /// tries first. Consumers persist it on the Saved Daemon.
    case selectedCandidate(DaemonEndpoint)
}

/// Owns the reconnect policy the shipped web and desktop clients never built:
/// exponential backoff with jitter, app-level keepalive pings, replay-cursor
/// carry-over between connections, candidate failover, and hard-fail on
/// rejection (a bad token or protocol mismatch never retries).
///
/// A daemon is reachable at several addresses at once — LAN, `.local`,
/// tailnet — and which of them works changes as the phone moves between
/// networks. One reconnect attempt therefore walks the whole candidate list
/// before any backoff: only when every address has failed has the daemon
/// really gone away. The candidate that last completed a handshake is tried
/// first, so a phone settled on the tailnet does not re-walk LAN addresses
/// that can only time out.
public actor ConnectionSupervisor {
    private var candidates: [DaemonEndpoint]
    private let clientId: UUID
    private let pingInterval: Duration
    private let candidateTimeout: Duration

    private var client: ShidouDaemonClient?
    private var carriedCursors: [ReplayCursor] = []
    private var subscribers: [UUID: AsyncStream<SupervisedEvent>.Continuation] = [:]
    private var runLoop: Task<Void, Never>?
    private var pingLoop: Task<Void, Never>?
    private var retryNow: CheckedContinuation<Void, Never>?
    private var suspended = false
    /// Whether any candidate has ever served this supervisor.
    ///
    /// Kept apart from the attempt counter on purpose: that counter paces
    /// backoff and resets to zero after a connection lives, so it cannot also
    /// answer "is this the first connection". Reading it that way silently
    /// swallowed `.reconnected` for the most common case — a clean drop that
    /// reconnects on the next round — which is exactly when consumers are
    /// holding a stale projection.
    private var hasConnectedBefore = false
    private(set) public var phase: ConnectionPhase = .idle

    /// `candidates` are tried in order on the first attempt; afterwards the
    /// last-good one leads. An empty list is a programmer error — pairing
    /// always yields at least one address.
    /// `candidateTimeout` bounds one handshake. Without it the walk inherits
    /// URLSession's 60-second default, and a single dead address — a LAN IP
    /// after the phone leaves Wi-Fi, a `.local` name with no mDNS to resolve
    /// it — holds the whole list hostage while the address that would work
    /// waits its turn.
    public init(
        candidates: [DaemonEndpoint],
        clientId: UUID = UUID(),
        pingInterval: Duration = .seconds(20),
        candidateTimeout: Duration = .seconds(8)
    ) {
        precondition(!candidates.isEmpty, "a supervisor needs at least one candidate address")
        self.candidates = candidates
        self.clientId = clientId
        self.pingInterval = pingInterval
        self.candidateTimeout = candidateTimeout
    }

    public init(
        endpoint: DaemonEndpoint,
        clientId: UUID = UUID(),
        pingInterval: Duration = .seconds(20),
        candidateTimeout: Duration = .seconds(8)
    ) {
        self.init(
            candidates: [endpoint],
            clientId: clientId,
            pingInterval: pingInterval,
            candidateTimeout: candidateTimeout
        )
    }

    /// The candidates in the order the next attempt will try them.
    public var candidateOrder: [DaemonEndpoint] { candidates }

    // MARK: - Public surface

    public func start(resumeFrom: [ReplayCursor] = []) {
        guard runLoop == nil else { return }
        carriedCursors = resumeFrom
        runLoop = Task { await self.run() }
    }

    /// Foreground/network-change hook: skips any pending backoff delay.
    public func retryImmediately() {
        suspended = false
        retryNow?.resume()
        retryNow = nil
    }

    /// Background hook: drops the socket and pauses reconnection until
    /// `retryImmediately()`. Cursors are preserved for the next connection.
    public func suspend() async {
        suspended = true
        if let client {
            carriedCursors = await client.replayCursors()
            await client.disconnect()
        }
    }

    public func stop() async {
        runLoop?.cancel()
        runLoop = nil
        pingLoop?.cancel()
        pingLoop = nil
        if let client {
            await client.disconnect()
        }
        client = nil
        // A later `start()` is a fresh session, so its first connection is
        // again a connection rather than a reconnect.
        hasConnectedBefore = false
        setPhase(.idle)
        for subscriber in subscribers.values { subscriber.finish() }
        subscribers.removeAll()
    }

    public func events() -> AsyncStream<SupervisedEvent> {
        let id = UUID()
        return AsyncStream { continuation in
            continuation.yield(.phase(phase))
            subscribers[id] = continuation
            continuation.onTermination = { _ in
                Task { await self.removeSubscriber(id) }
            }
        }
    }

    /// The live client for issuing requests; throws when disconnected.
    public func currentClient() throws -> ShidouDaemonClient {
        guard let client, case .connected = phase else {
            throw ShidouError.disconnected
        }
        return client
    }

    /// Cursors for persisting across app launches.
    public func replayCursors() async -> [ReplayCursor] {
        if let client {
            return await client.replayCursors()
        }
        return carriedCursors
    }

    // MARK: - Run loop

    /// What one pass over the candidate list came to.
    private enum RoundOutcome {
        /// A candidate connected and the socket has since closed; reconnect
        /// with a fresh attempt counter.
        case served
        /// Every candidate failed for a reason time might fix.
        case exhausted(String)
        /// A candidate answered in a way retrying cannot fix.
        case terminal(ConnectionFailure)
        /// `suspend()` landed mid-round; the run loop parks.
        case interrupted
    }

    private func run() async {
        var attempt = 0
        while !Task.isCancelled {
            if suspended {
                await waitForRetrySignal()
                continue
            }
            attempt += 1
            switch await runRound(attempt: attempt) {
            case .served:
                // A connection that lived is not evidence of a flaky network:
                // the next drop starts its backoff from the bottom again.
                attempt = 0
            case .terminal(let failure):
                setPhase(.failed(failure))
                return
            case .interrupted:
                continue
            case .exhausted(let lastError):
                if Task.isCancelled { return }
                let delay = Self.backoffDelay(attempt: attempt)
                setPhase(.backingOff(
                    nextAttempt: attempt + 1, delay: delay, lastError: lastError
                ))
                await sleepInterruptibly(delay)
            }
        }
    }

    /// One walk down the candidate list. Returns as soon as a candidate
    /// connects (after that connection ends) rather than trying the rest.
    private func runRound(attempt: Int) async -> RoundOutcome {
        var lastError = ShidouError.disconnected.localizedDescription
        for endpoint in candidates {
            if Task.isCancelled { return .interrupted }
            if suspended { return .interrupted }
            setPhase(.connecting(attempt: attempt, endpoint: endpoint))
            let client = ShidouDaemonClient(endpoint: endpoint, clientId: clientId)
            do {
                let events = await client.events()
                let cursors = carriedCursors
                let hello = try await Self.withDeadline(candidateTimeout) {
                    try await client.connect(resumeFrom: cursors)
                } onExpiry: {
                    // The socket may still be mid-handshake; drop it so a
                    // late success cannot resurrect an abandoned candidate.
                    await client.disconnect()
                }
                if suspended || Task.isCancelled {
                    // `suspend()` or `stop()` landed while the handshake was
                    // in flight. Both looked for a client to close and found
                    // none, because this one is not adopted until the line
                    // below — so closing it is this scope's job. Adopting it
                    // instead leaves a socket live in the background, which
                    // is the one thing Suspend exists to prevent.
                    carriedCursors = await client.replayCursors()
                    await client.disconnect()
                    return .interrupted
                }
                self.client = client
                promote(endpoint)
                broadcast(.selectedCandidate(endpoint))
                setPhase(.connected(hello, endpoint: endpoint))
                // The app's own first connection is not a reconnect; every
                // one after it means consumers are holding stale projections.
                if hasConnectedBefore {
                    broadcast(.reconnected(hello))
                }
                hasConnectedBefore = true
                startPinging(client)
                // Blocks until the connection dies; events flow to subscribers.
                await pump(events)
                pingLoop?.cancel()
                pingLoop = nil
                carriedCursors = await client.replayCursors()
                self.client = nil
                return .served
            } catch let error as ShidouError {
                await client.disconnect()
                switch error {
                case .rejected(let message):
                    return .terminal(.tokenRejected(message))
                case .invalidHandshake(let detail):
                    return .terminal(.protocolMismatch(detail))
                case .invalidAddress(let address):
                    return .terminal(.invalidAddress(address))
                default:
                    lastError = error.localizedDescription
                }
            } catch {
                // Includes the cancellation `stop()` raises mid-handshake.
                // The client was never adopted, so nothing else holds a
                // reference that would invalidate its URLSession.
                await client.disconnect()
                lastError = error.localizedDescription
            }
        }
        return .exhausted(lastError)
    }

    /// Runs `operation`, giving up after `deadline`.
    ///
    /// The loser of the race is cancelled, and `onExpiry` runs on a timeout so
    /// the caller can tear down whatever the operation left half-built.
    private static func withDeadline<T: Sendable>(
        _ deadline: Duration,
        operation: @escaping @Sendable () async throws -> T,
        onExpiry: @escaping @Sendable () async -> Void
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T?.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(for: deadline)
                return nil
            }
            defer { group.cancelAll() }
            while let result = try await group.next() {
                guard let result else {
                    await onExpiry()
                    throw ShidouError.requestTimeout
                }
                return result
            }
            throw ShidouError.disconnected
        }
    }

    /// Move the candidate that just handshook to the front of the list.
    private func promote(_ endpoint: DaemonEndpoint) {
        guard candidates.first != endpoint, let index = candidates.firstIndex(of: endpoint) else {
            return
        }
        candidates.remove(at: index)
        candidates.insert(endpoint, at: 0)
    }

    private func pump(_ events: AsyncStream<ConnectionEvent>) async {
        for await item in events {
            switch item {
            case .event(let event):
                broadcast(.event(event))
            case .taskStateChanged(let revision):
                broadcast(.taskStateChanged(revision: revision))
            case .replayGap(let gap):
                broadcast(.replayGap(gap))
            case .disconnected:
                return
            }
        }
    }

    private func startPinging(_ client: ShidouDaemonClient) {
        pingLoop?.cancel()
        let interval = pingInterval
        pingLoop = Task {
            var failures = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                if Task.isCancelled { return }
                do {
                    try await client.ping()
                    failures = 0
                } catch {
                    failures += 1
                    if failures >= 2 {
                        // The read loop may not notice a half-open socket;
                        // force the disconnect so the run loop reconnects.
                        await client.disconnect()
                        return
                    }
                }
            }
        }
    }

    /// 0.5s, 1s, 2s, 4s, 8s, then 15s cap, ±20% jitter.
    static func backoffDelay(attempt: Int) -> Duration {
        let base = min(0.5 * pow(2.0, Double(max(0, attempt - 1))), 15.0)
        let jitter = Double.random(in: 0.8...1.2)
        return .milliseconds(Int(base * jitter * 1000))
    }

    private func sleepInterruptibly(_ delay: Duration) async {
        await withCheckedContinuation { continuation in
            retryNow = continuation
            Task {
                try? await Task.sleep(for: delay)
                self.resumeRetry()
            }
        }
    }

    private func resumeRetry() {
        retryNow?.resume()
        retryNow = nil
    }

    private func waitForRetrySignal() async {
        await withCheckedContinuation { continuation in
            retryNow = continuation
        }
    }

    private func setPhase(_ phase: ConnectionPhase) {
        self.phase = phase
        broadcast(.phase(phase))
    }

    private func broadcast(_ event: SupervisedEvent) {
        for subscriber in subscribers.values {
            subscriber.yield(event)
        }
    }

    private func removeSubscriber(_ id: UUID) {
        subscribers.removeValue(forKey: id)
    }
}
