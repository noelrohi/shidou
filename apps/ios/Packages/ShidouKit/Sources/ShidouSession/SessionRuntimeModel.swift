import Foundation
import Observation
import ShidouProtocol

/// Observable state for one open session. Reducer mutations land in an
/// unobserved projection; `session` republishes on a bounded cadence so a
/// token-rate `textDelta` stream cannot invalidate SwiftUI per event
/// (mirrors the desktop's stream-commit cadence in docs/performance.md).
@Observable
@MainActor
public final class SessionRuntimeModel {
    public private(set) var session: AgentSession
    public private(set) var runtimeId: UUID?
    public private(set) var supportsSteer = false
    public private(set) var pendingPermission: PendingPermission?
    public private(set) var pendingUserInput: PendingUserInput?
    public private(set) var isAttached = false
    /// Set while a reconnect replay or hydration is in flight so views can
    /// show a catch-up treatment instead of a half-applied transcript.
    public private(set) var isCatchingUp = false

    @ObservationIgnored var lastDriverError: String?
    @ObservationIgnored private var projection: AgentSession
    @ObservationIgnored private var dirty = false
    @ObservationIgnored private var publishTask: Task<Void, Never>?
    @ObservationIgnored private var publishHeld = false

    private static let publishInterval: Duration = .milliseconds(80)

    public init(session: AgentSession) {
        self.session = session
        self.projection = session
    }

    /// The projection is the source of truth for reducer input and
    /// persistence; `session` may lag it by one publish tick.
    public var currentProjection: AgentSession { projection }

    public func setRuntime(id: UUID?, supportsSteer: Bool) {
        runtimeId = id
        self.supportsSteer = supportsSteer
        isAttached = true
    }

    public func clearRuntime() {
        runtimeId = nil
        supportsSteer = false
    }

    /// Replaces the whole projection (hydration, fork/rewind responses,
    /// local mutations like `beginTurn`). Publishes immediately.
    public func replaceSession(_ session: AgentSession) {
        projection = session
        publishNow()
    }

    /// Suppress per-event publishing during a replay burst; `endCatchUp`
    /// flushes once.
    public func beginCatchUp() {
        publishHeld = true
        isCatchingUp = true
    }

    public func endCatchUp() {
        publishHeld = false
        isCatchingUp = false
        publishNow()
    }

    /// Applies one daemon event through the shared reducer. Returns the
    /// reducer verdict so the store can persist/settle/remove the runtime.
    @discardableResult
    public func apply(_ event: SequencedEvent, clock: ReducerClock = .live) -> RuntimeEventResult? {
        guard !runtimeEventAlreadyApplied(session: projection, event: event) else { return nil }
        var result = reduceRuntimeEvent(
            projection, event, clock: clock, processExitError: lastDriverError
        )
        if let requestId = result.resolvedInteractionId {
            let matchesPermission = pendingPermission?.requestId == requestId
            let matchesUserInput = pendingUserInput?.requestId == requestId
            if matchesPermission { pendingPermission = nil }
            if matchesUserInput { pendingUserInput = nil }
            if (matchesPermission || matchesUserInput), result.session.status == .waiting {
                result.session.status = .working
            }
        }
        projection = result.session
        if let error = result.error {
            lastDriverError = error
        }
        if case .some(let permission) = result.permission {
            pendingPermission = permission
        }
        if case .some(let userInput) = result.userInput {
            pendingUserInput = userInput
        }
        if result.settled || result.removeRuntime {
            lastDriverError = nil
            publishNow()
        } else {
            schedulePublish()
        }
        if result.removeRuntime {
            clearRuntime()
        }
        return result
    }

    public func clearPendingPermission() {
        pendingPermission = nil
    }

    public func clearPendingUserInput() {
        pendingUserInput = nil
    }

    private func schedulePublish() {
        dirty = true
        guard !publishHeld, publishTask == nil else { return }
        publishTask = Task { [weak self] in
            try? await Task.sleep(for: Self.publishInterval)
            guard let self else { return }
            self.publishTask = nil
            if self.dirty && !self.publishHeld {
                self.publishNow()
            }
        }
    }

    private func publishNow() {
        dirty = false
        session = projection
    }
}
