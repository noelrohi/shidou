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
    public private(set) var recordedEdits: [UUID: RecordedEdits]
    public private(set) var runtimeId: UUID?
    public private(set) var supportsSteer = false
    public private(set) var pendingPermission: PendingPermission?
    public private(set) var pendingUserInput: PendingUserInput?
    public private(set) var isAttached = false
    /// Set while a reconnect replay or hydration is in flight so views can
    /// show a catch-up treatment instead of a half-applied transcript.
    public private(set) var isCatchingUp = false
    /// Detached processes, monitors and subagents for this session. Kept off
    /// the projection on purpose: this work outlives the turn that started it,
    /// so folding it in would make a finished turn look like finished work.
    /// Never persisted — `refreshBackgroundWork` is how a fresh screen learns
    /// what is still running.
    public private(set) var backgroundWork = BackgroundWorkLedger()

    @ObservationIgnored var lastDriverError: String?
    @ObservationIgnored private var projection: AgentSession
    @ObservationIgnored private var dirty = false
    @ObservationIgnored private var recordedEditsDirty = false
    @ObservationIgnored private var publishTask: Task<Void, Never>?
    @ObservationIgnored private var publishHeld = false

    private static let publishInterval: Duration = .milliseconds(80)

    public init(session: AgentSession) {
        self.session = session
        self.recordedEdits = RecordedEdits.summaries(in: session)
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
        // Whatever was still running belonged to a runtime that is gone. A
        // spinner against work nobody can reach is worse than saying so.
        backgroundWork.markLost(now: nowMillis())
    }

    /// Local echo for a stop the user just asked for, so the row changes on
    /// the tap rather than on the daemon's reply.
    public func markBackgroundWorkStopping(_ key: BackgroundWorkKey) {
        backgroundWork.markStopping(key, now: nowMillis())
    }

    public func markBackgroundWorkLost() {
        backgroundWork.markLost(now: nowMillis())
    }

    /// The stop never reached the daemon, so the work is still running. Same
    /// shape as the daemon's own `stopFailed`, because it means the same thing.
    public func backgroundWorkStopFailed(_ key: BackgroundWorkKey, message: String) {
        backgroundWork.apply(.stopFailed(key: key, message: message), now: nowMillis())
    }

    private func nowMillis() -> UInt64 { UInt64(Date().timeIntervalSince1970 * 1000) }

    /// Replaces the whole projection (hydration, fork/rewind responses,
    /// local mutations like `beginTurn`). Publishes immediately.
    public func replaceSession(_ session: AgentSession) {
        projection = session
        recordedEditsDirty = true
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
        // The kind check comes first so a streaming text delta does not pay a
        // whole `DriverEvent` decode just to be told it is not background
        // work; the reducer below reads `kind` and `payload` directly.
        if event.event.kind == "backgroundWork",
            case .backgroundWork(let work) = DriverEvent(wire: event.event)
        {
            // Background work is not part of the projection, so it never
            // reaches the reducer — but the cursor still has to advance, which
            // the reducer below does for every event including this one.
            backgroundWork.apply(work, clock: clock)
        }
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
        // Activity upserts can replace an existing file edit, even when the
        // incoming kind is different. Acceptance can remap block turn IDs;
        // settlement marks pending activities complete. Deltas and usage do
        // not change recorded edits and must not rescan historical blocks.
        switch event.event.kind {
        case "activity", "richActivity", "turnAccepted", "turnFinished", "processExited":
            recordedEditsDirty = true
        default:
            break
        }
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

    /// Re-attaches a prompt the store was holding for a session that had no
    /// projection yet.
    public func restore(permission: PendingPermission) {
        pendingPermission = permission
    }

    public func restore(userInput: PendingUserInput) {
        pendingUserInput = userInput
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
        if recordedEditsDirty {
            recordedEdits = RecordedEdits.summaries(in: projection)
            recordedEditsDirty = false
        }
        session = projection
    }
}
