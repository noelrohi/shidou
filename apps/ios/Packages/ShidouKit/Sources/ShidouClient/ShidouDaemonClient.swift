import Foundation
import ShidouProtocol

public struct DaemonHello: Sendable {
    public let protocolVersion: UInt32
    public let daemonVersion: String
}

public enum ConnectionEvent: Sendable {
    case event(SequencedEvent)
    case taskStateChanged(revision: UInt64)
    case disconnected
}

/// One WebSocket connection to the Shidou daemon: handshake, request/response
/// correlation, and sequenced-event fanout. Reconnect policy lives above this
/// in `ConnectionSupervisor`; a client instance is single-use.
public actor ShidouDaemonClient {
    private struct SubscriptionKey: Hashable {
        let sessionId: UUID
        let runtimeId: UUID
    }

    private let endpoint: DaemonEndpoint
    private let clientId: UUID
    private let requestTimeout: Duration

    private var task: URLSessionWebSocketTask?
    private var urlSession: URLSession?
    private var readLoop: Task<Void, Never>?
    private var pending: [UUID: CheckedContinuation<ResponseOutcome, Error>] = [:]
    private var lastSeen: [SubscriptionKey: (epoch: UUID, sequence: UInt64)] = [:]
    private var subscribers: [UUID: AsyncStream<ConnectionEvent>.Continuation] = [:]
    private var closed = false

    public init(
        endpoint: DaemonEndpoint,
        clientId: UUID = UUID(),
        requestTimeout: Duration = .seconds(120)
    ) {
        self.endpoint = endpoint
        self.clientId = clientId
        self.requestTimeout = requestTimeout
    }

    // MARK: - Lifecycle

    /// Opens the socket and completes the hello handshake. `resumeFrom`
    /// replays journaled events past each cursor once the handshake lands.
    public func connect(resumeFrom: [ReplayCursor] = []) async throws -> DaemonHello {
        precondition(task == nil, "a ShidouDaemonClient connects at most once")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.waitsForConnectivity = false
        let session = URLSession(configuration: configuration)
        let socket = session.webSocketTask(with: endpoint.url)
        socket.maximumMessageSize = ShidouWire.maxWireMessageBytes
        urlSession = session
        task = socket
        socket.resume()

        for cursor in resumeFrom {
            lastSeen[SubscriptionKey(sessionId: cursor.sessionId, runtimeId: cursor.runtimeId)] =
                (cursor.epoch, cursor.sequence)
        }

        try await send(.hello(token: endpoint.token, clientId: clientId, resumeFrom: resumeFrom))
        let first = try await receiveMessage(socket)
        switch first {
        case .hello(let protocolVersion, let daemonVersion):
            guard protocolVersion == ShidouWire.protocolVersion else {
                disconnect(error: ShidouError.invalidHandshake("protocol version mismatch"))
                throw ShidouError.invalidHandshake(
                    "daemon speaks protocol \(protocolVersion), this app speaks \(ShidouWire.protocolVersion)"
                )
            }
            startReadLoop()
            return DaemonHello(protocolVersion: protocolVersion, daemonVersion: daemonVersion)
        case .rejected(let message):
            disconnect(error: ShidouError.rejected(message: message))
            throw ShidouError.rejected(message: message)
        default:
            disconnect(error: ShidouError.invalidHandshake("unexpected first frame"))
            throw ShidouError.invalidHandshake("the daemon sent an unexpected first frame")
        }
    }

    public var isConnected: Bool {
        task != nil && !closed
    }

    public func disconnect() {
        disconnect(error: ShidouError.disconnected)
    }

    private func disconnect(error: Error) {
        guard !closed else { return }
        closed = true
        readLoop?.cancel()
        readLoop = nil
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        urlSession?.invalidateAndCancel()
        urlSession = nil
        for continuation in pending.values {
            continuation.resume(throwing: error)
        }
        pending.removeAll()
        for subscriber in subscribers.values {
            subscriber.yield(.disconnected)
            subscriber.finish()
        }
        subscribers.removeAll()
    }

    // MARK: - Requests

    /// Sends a command and awaits its correlated response payload.
    /// RPC-level errors surface as `ShidouError.rpc`.
    public func request(
        _ command: Command,
        sessionId: UUID = .zero,
        runtimeId: UUID = .zero,
        requestId: UUID = UUID()
    ) async throws -> ResponsePayload {
        guard isConnected else { throw ShidouError.disconnected }
        let request = Request(
            requestId: requestId, sessionId: sessionId, runtimeId: runtimeId, command: command
        )
        try await send(.request(request))

        let timeout = requestTimeout
        let outcome: ResponseOutcome = try await withCheckedThrowingContinuation { continuation in
            pending[requestId] = continuation
            Task {
                try? await Task.sleep(for: timeout)
                self.failPending(requestId: requestId)
            }
        }
        switch outcome {
        case .ok(let payload):
            return payload
        case .error(let error):
            throw ShidouError.rpc(message: error.message)
        }
    }

    /// Fire-and-forget: ordered like a request but the daemon sends no
    /// response (nil request id).
    public func notify(_ command: Command, sessionId: UUID, runtimeId: UUID) async throws {
        guard isConnected else { throw ShidouError.disconnected }
        try await send(.request(Request(
            requestId: .zero, sessionId: sessionId, runtimeId: runtimeId, command: command
        )))
    }

    /// WebSocket-level ping. The daemon flushes on ping; a failure means the
    /// socket is dead even if the OS hasn't noticed yet.
    public func ping() async throws {
        guard let task else { throw ShidouError.disconnected }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            task.sendPing { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }

    // MARK: - Events

    /// Sequenced events and task-state pings, deduplicated per runtime.
    /// Attach the stream before issuing `attachSession` so nothing is missed.
    public func events() -> AsyncStream<ConnectionEvent> {
        let id = UUID()
        return AsyncStream { continuation in
            if closed {
                continuation.yield(.disconnected)
                continuation.finish()
                return
            }
            subscribers[id] = continuation
            continuation.onTermination = { _ in
                Task { await self.removeSubscriber(id) }
            }
        }
    }

    /// Cursors describing every event applied on this connection; feed these
    /// into the next connection's `resumeFrom`.
    public func replayCursors() -> [ReplayCursor] {
        lastSeen.map { key, value in
            ReplayCursor(
                sessionId: key.sessionId,
                runtimeId: key.runtimeId,
                epoch: value.epoch,
                sequence: value.sequence
            )
        }
    }

    public func lastSequence(sessionId: UUID, runtimeId: UUID) -> UInt64? {
        lastSeen[SubscriptionKey(sessionId: sessionId, runtimeId: runtimeId)]?.sequence
    }

    // MARK: - Internals

    private func removeSubscriber(_ id: UUID) {
        subscribers.removeValue(forKey: id)
    }

    private func failPending(requestId: UUID) {
        pending.removeValue(forKey: requestId)?.resume(throwing: ShidouError.requestTimeout)
    }

    private func send(_ message: ClientMessage) async throws {
        guard let task else { throw ShidouError.disconnected }
        let data = try JSONEncoder().encode(message)
        guard let text = String(data: data, encoding: .utf8) else {
            throw ShidouError.invalidHandshake("frame is not utf-8")
        }
        try await task.send(.string(text))
    }

    private func receiveMessage(_ socket: URLSessionWebSocketTask) async throws -> ServerMessage {
        try await receiveDecoded(socket)
    }

    private func startReadLoop() {
        guard let socket = task else { return }
        readLoop = Task {
            while !Task.isCancelled {
                do {
                    let message = try await self.receiveDecoded(socket)
                    self.handle(message)
                } catch is CancellationError {
                    return
                } catch is DecodingError {
                    // One undecodable frame must not kill the connection.
                    continue
                } catch {
                    self.handleReadFailure(error)
                    return
                }
            }
        }
    }

    private nonisolated func receiveDecoded(_ socket: URLSessionWebSocketTask) async throws -> ServerMessage {
        let raw = try await socket.receive()
        let data: Data
        switch raw {
        case .string(let text):
            data = Data(text.utf8)
        case .data(let bytes):
            data = bytes
        @unknown default:
            throw ShidouError.invalidHandshake("unsupported frame type")
        }
        return try JSONDecoder().decode(ServerMessage.self, from: data)
    }

    private func handleReadFailure(_ error: Error) {
        disconnect(error: error)
    }

    private func handle(_ message: ServerMessage) {
        switch message {
        case .response(let requestId, let outcome):
            pending.removeValue(forKey: requestId)?.resume(returning: outcome)
        case .event(let event):
            let key = SubscriptionKey(sessionId: event.sessionId, runtimeId: event.runtimeId)
            if let seen = lastSeen[key], seen.epoch == event.epoch, event.sequence <= seen.sequence {
                return
            }
            lastSeen[key] = (event.epoch, event.sequence)
            for subscriber in subscribers.values {
                subscriber.yield(.event(event))
            }
        case .taskStateChanged(let revision):
            for subscriber in subscribers.values {
                subscriber.yield(.taskStateChanged(revision: revision))
            }
        case .shuttingDown:
            disconnect(error: ShidouError.shuttingDown)
        case .hello, .rejected, .unknown:
            break
        }
    }
}
