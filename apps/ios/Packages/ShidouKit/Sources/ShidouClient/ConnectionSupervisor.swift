import Foundation
import ShidouProtocol

public enum ConnectionPhase: Sendable, Equatable {
    case idle
    case connecting(attempt: Int)
    case connected(DaemonHello)
    case backingOff(nextAttempt: Int, delay: Duration, lastError: String)
    case failed(String)

    public static func == (lhs: ConnectionPhase, rhs: ConnectionPhase) -> Bool {
        switch (lhs, rhs) {
        case (.idle, .idle): return true
        case (.connecting(let a), .connecting(let b)): return a == b
        case (.connected, .connected): return true
        case (.backingOff(let a, _, _), .backingOff(let b, _, _)): return a == b
        case (.failed(let a), .failed(let b)): return a == b
        default: return false
        }
    }
}

public enum SupervisedEvent: Sendable {
    case phase(ConnectionPhase)
    case event(SequencedEvent)
    case taskStateChanged(revision: UInt64)
    /// A fresh connection completed its handshake. Consumers should re-attach
    /// sessions and refetch task state; replayed events follow on the stream.
    case reconnected(DaemonHello)
}

/// Owns the reconnect policy the shipped web and desktop clients never built:
/// exponential backoff with jitter, app-level keepalive pings, replay-cursor
/// carry-over between connections, and hard-fail on rejection (a bad token or
/// protocol mismatch never retries).
public actor ConnectionSupervisor {
    private let endpoint: DaemonEndpoint
    private let clientId: UUID
    private let pingInterval: Duration

    private var client: ShidouDaemonClient?
    private var carriedCursors: [ReplayCursor] = []
    private var subscribers: [UUID: AsyncStream<SupervisedEvent>.Continuation] = [:]
    private var runLoop: Task<Void, Never>?
    private var pingLoop: Task<Void, Never>?
    private var retryNow: CheckedContinuation<Void, Never>?
    private var suspended = false
    private(set) public var phase: ConnectionPhase = .idle

    public init(endpoint: DaemonEndpoint, clientId: UUID = UUID(), pingInterval: Duration = .seconds(20)) {
        self.endpoint = endpoint
        self.clientId = clientId
        self.pingInterval = pingInterval
    }

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

    private func run() async {
        var attempt = 0
        while !Task.isCancelled {
            if suspended {
                await waitForRetrySignal()
                continue
            }
            attempt += 1
            setPhase(.connecting(attempt: attempt))
            let client = ShidouDaemonClient(endpoint: endpoint, clientId: clientId)
            do {
                let cursors = carriedCursors
                let events = await client.events()
                let hello = try await client.connect(resumeFrom: cursors)
                self.client = client
                let firstConnection = attempt == 1
                attempt = 0
                setPhase(.connected(hello))
                if !firstConnection {
                    broadcast(.reconnected(hello))
                }
                startPinging(client)
                // Blocks until the connection dies; events flow to subscribers.
                await pump(events)
                pingLoop?.cancel()
                pingLoop = nil
                carriedCursors = await client.replayCursors()
                self.client = nil
            } catch let error as ShidouError {
                self.client = nil
                switch error {
                case .rejected, .invalidHandshake, .invalidAddress:
                    // Retrying cannot fix a bad token or version mismatch.
                    setPhase(.failed(error.localizedDescription))
                    return
                default:
                    break
                }
            } catch {
                self.client = nil
            }
            if Task.isCancelled { return }
            let delay = Self.backoffDelay(attempt: attempt)
            setPhase(.backingOff(
                nextAttempt: attempt + 1, delay: delay,
                lastError: ShidouError.disconnected.localizedDescription
            ))
            await sleepInterruptibly(delay)
        }
    }

    private func pump(_ events: AsyncStream<ConnectionEvent>) async {
        for await item in events {
            switch item {
            case .event(let event):
                broadcast(.event(event))
            case .taskStateChanged(let revision):
                broadcast(.taskStateChanged(revision: revision))
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
