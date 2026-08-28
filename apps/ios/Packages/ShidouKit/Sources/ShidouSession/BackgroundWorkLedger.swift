import Foundation
import ShidouProtocol

/// Port of the background-work reducer in `apps/web/src/lib/runtime-context.tsx`.
///
/// Background work is deliberately not part of the session projection: a
/// detached process or a subagent outlives the turn that started it, so
/// folding it into the transcript would make finishing a turn look like
/// finishing the work. It is per-session runtime state instead, rebuilt from
/// events and never persisted — which is also why it is a plain value type
/// with a reducer rather than another observable object.
public struct BackgroundWorkLedger: Sendable, Equatable {
    /// Same bounds as the web client. Divergence here would mean the phone
    /// showed less of a process's output than the desktop did for the same
    /// run, which reads as a truncated log rather than a different budget.
    static let maxOutputCharacters = 512 * 1024
    static let maxSettledItems = 24

    public private(set) var items: [BackgroundWorkItem] = []

    public init(items: [BackgroundWorkItem] = []) {
        self.items = items
    }

    public var isEmpty: Bool { items.isEmpty }

    /// Live work first, each group newest-first — a phone shows a short list
    /// and what is still running is what the user came for.
    public var ordered: [BackgroundWorkItem] {
        items.sorted { left, right in
            if left.status.isLive != right.status.isLive { return left.status.isLive }
            return left.updatedAtMs > right.updatedAtMs
        }
    }

    public var liveCount: Int { items.filter { $0.status.isLive }.count }

    public func item(for key: BackgroundWorkKey) -> BackgroundWorkItem? {
        items.first { $0.key == key }
    }

    public mutating func apply(_ event: BackgroundWorkEvent, clock: ReducerClock) {
        apply(event, now: clock.nowMillis())
    }

    public mutating func apply(_ event: BackgroundWorkEvent, now: UInt64) {
        switch event {
        case .upsert(let item):
            upsert(item)
        case .outputDelta(let key, let delta):
            for index in items.indices where items[index].key == key {
                // Appended in place rather than built with `+`: dropping the
                // item's own reference first leaves the buffer uniquely
                // referenced, so a delta costs its own length instead of a
                // copy of the whole log. Output deltas arrive at streaming
                // cadence, and this one is half a megabyte at its bound.
                var combined = items[index].output ?? ""
                items[index].output = nil
                combined.append(delta)
                items[index].outputTruncated =
                    items[index].outputTruncated || Self.exceedsBudget(combined)
                items[index].output = Self.bound(combined)
                items[index].updatedAtMs = now
            }
        case .reconcileProcesses(let incoming):
            reconcile(incoming, allKinds: false, now: now)
        case .reconcileLive(let incoming):
            reconcile(incoming, allKinds: true, now: now)
        case .stopRequested(let key):
            for index in items.indices where items[index].key == key {
                items[index].status = .stopping
                items[index].updatedAtMs = now
            }
        case .stopFailed(let key, let message):
            // A stop that failed leaves the work running, so the item goes
            // back to running and carries the reason rather than sitting in
            // `stopping` forever.
            for index in items.indices
            where items[index].key == key && items[index].status.isLive {
                items[index].detail = message
                items[index].status = items[index].key.kind == .monitor ? .monitoring : .running
                items[index].updatedAtMs = now
            }
        case .unknown:
            return
        }
        trimSettled()
    }

    /// Everything still live is now unaccounted for — the runtime that owned
    /// it went away. Saying "lost" beats leaving a spinner running against a
    /// process nobody can reach.
    public mutating func markLost(now: UInt64) {
        for index in items.indices where items[index].status.isLive {
            items[index].status = .lost
            items[index].canStop = false
            items[index].updatedAtMs = now
        }
    }

    /// Optimistic local echo for a stop the user just asked for, so the row
    /// changes the instant it is tapped rather than at the daemon's leisure.
    public mutating func markStopping(_ key: BackgroundWorkKey, now: UInt64) {
        apply(.stopRequested(key), now: now)
    }

    private mutating func upsert(_ incoming: BackgroundWorkItem) {
        let index = items.firstIndex { $0.key == incoming.key }
        let existing = index.map { items[$0] }
        // Foreground work that has already settled is transcript activity,
        // not background work; it only belongs here once it detaches.
        if incoming.key.kind != .subagent, !incoming.background,
            existing?.background != true, !incoming.status.isLive
        {
            if let index { items.remove(at: index) }
            return
        }
        let output = incoming.output.map(Self.bound) ?? existing?.output
        guard var existing, let index else {
            var fresh = incoming
            fresh.output = output
            fresh.outputTruncated =
                incoming.outputTruncated || (incoming.output.map(Self.exceedsBudget) ?? false)
            items.append(fresh)
            return
        }
        let wasStopping = existing.status == .stopping
        existing.title = incoming.title.isEmpty ? existing.title : incoming.title
        existing.detail = incoming.detail ?? existing.detail
        existing.command = incoming.command ?? existing.command
        existing.cwd = incoming.cwd ?? existing.cwd
        existing.outputTruncated =
            incoming.output == nil
            ? existing.outputTruncated
            : incoming.outputTruncated || (incoming.output.map(Self.exceedsBudget) ?? false)
        existing.output = output
        existing.startedAtMs = min(existing.startedAtMs, incoming.startedAtMs)
        existing.updatedAtMs = max(existing.updatedAtMs, incoming.updatedAtMs)
        existing.durationMs = incoming.durationMs ?? existing.durationMs
        existing.exitCode = incoming.exitCode ?? existing.exitCode
        existing.background = existing.background || incoming.background
        existing.canStop = incoming.status.isLive ? existing.canStop || incoming.canStop : false
        existing.controlId = incoming.controlId ?? existing.controlId
        existing.originActivityId = incoming.originActivityId ?? existing.originActivityId
        existing.role = incoming.role ?? existing.role
        existing.model = incoming.model ?? existing.model
        existing.parentId = incoming.parentId ?? existing.parentId
        // A stop already asked for outranks a status the provider emitted
        // before it heard about it.
        existing.status =
            wasStopping && incoming.status.isStoppable ? .stopping : incoming.status
        items[index] = existing
    }

    /// A reconcile is authoritative for the kinds it covers: live work it does
    /// not mention is work whose owner is gone.
    private mutating func reconcile(
        _ incoming: [BackgroundWorkItem], allKinds: Bool, now: UInt64
    ) {
        let present = Set(incoming.map(\.key))
        for index in items.indices {
            let includedKind = allKinds || items[index].key.kind != .subagent
            guard includedKind, items[index].background, items[index].status.isLive,
                !present.contains(items[index].key)
            else { continue }
            items[index].status = .lost
            items[index].canStop = false
            items[index].updatedAtMs = now
        }
        for item in incoming { upsert(item) }
    }

    private mutating func trimSettled() {
        let settled = items.filter { !$0.status.isLive }
        guard settled.count > Self.maxSettledItems else { return }
        let remove = Set(settled.prefix(settled.count - Self.maxSettledItems).map(\.key))
        items.removeAll { remove.contains($0.key) }
    }

    /// Whether `output` is past the budget, without counting a whole log to
    /// find out. UTF-8 length is what the storage already holds and is never
    /// smaller than the character count, so anything inside the budget in
    /// bytes is inside it in characters too — which is every delta but the
    /// ones that actually overflow.
    private static func exceedsBudget(_ output: String) -> Bool {
        output.utf8.count > maxOutputCharacters && output.count > maxOutputCharacters
    }

    private static func bound(_ output: String) -> String {
        guard exceedsBudget(output) else { return output }
        return String(output.suffix(maxOutputCharacters))
    }
}
