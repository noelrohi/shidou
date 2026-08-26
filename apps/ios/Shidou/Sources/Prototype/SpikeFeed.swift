// PROTOTYPE — streaming transcript spike (wayfinder #9). Throwaway.
//
// Fake daemon: preloads a long transcript and streams live turns through the
// real reducer path (`SessionRuntimeModel.apply`), so the spike measures the
// same event → projection → publish pipeline the shipping client will use.

import Foundation
import Observation
import ShidouProtocol
import ShidouSession

@MainActor
@Observable
final class SpikeFeed {
    @ObservationIgnored let model: SessionRuntimeModel
    @ObservationIgnored private let sessionId = UUID()
    @ObservationIgnored private let runtimeId = UUID()
    @ObservationIgnored private let epoch = UUID()
    @ObservationIgnored private var sequence: UInt64 = 0
    @ObservationIgnored private var streamTask: Task<Void, Never>?
    private(set) var running = false

    /// Token deltas per second while streaming text/reasoning.
    var tokensPerSecond: Double = 40

    init() {
        model = SessionRuntimeModel(
            session: newSession(projectId: UUID(), provider: .claude, isolated: false))
    }

    // MARK: Preload

    /// Replace the session with `turns` completed turns of realistic content
    /// (markdown, code fences, reasoning, activity groups).
    func preload(turns: Int) {
        stop()
        var session = newSession(projectId: UUID(), provider: .claude, isolated: false)
        session.title = "Streaming spike"
        let now = unixTime()
        for turn in 0..<turns {
            let turnId = UUID()
            session.messages.append(
                Message(
                    turnId: turnId, role: .user,
                    content: SpikeCorpus.prompts[turn % SpikeCorpus.prompts.count],
                    createdAt: now))
            session.transcriptBlocks.append(
                TranscriptBlock(
                    afterMessage: session.messages.count, turnId: turnId,
                    activities: SpikeCorpus.activities(turn: turn)))
            session.messages.append(
                Message(
                    turnId: turnId, role: .assistant,
                    content: SpikeCorpus.responses[turn % SpikeCorpus.responses.count],
                    createdAt: now))
            session.turns.append(
                AgentTurn(
                    id: turnId, turnCount: turn + 1, status: .completed,
                    startedAt: now, completedAt: now))
        }
        model.replaceSession(session)
    }

    // MARK: Live stream

    func start() {
        guard !running else { return }
        running = true
        streamTask = Task { [weak self] in
            while let self, self.running, !Task.isCancelled {
                await self.streamOneTurn()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    func stop() {
        running = false
        streamTask?.cancel()
        streamTask = nil
    }

    private func streamOneTurn() async {
        let turnIndex = model.currentProjection.turns.count
        model.replaceSession(
            beginTurn(
                model.currentProjection,
                prompt: SpikeCorpus.prompts[turnIndex % SpikeCorpus.prompts.count]))
        apply(kind: "connected", payload: .object(["provider": .string("claude")]))
        apply(kind: "turnStarted", payload: .null)

        let reasoning = SpikeCorpus.reasoning[turnIndex % SpikeCorpus.reasoning.count]
        for chunk in SpikeCorpus.tokenize(reasoning) {
            guard running, !Task.isCancelled else { return }
            apply(kind: "reasoningDelta", payload: .string(chunk))
            await tick()
        }

        for (offset, activity) in SpikeCorpus.activities(turn: turnIndex).enumerated() {
            guard running, !Task.isCancelled else { return }
            let id = "spike-\(turnIndex)-\(offset)"
            apply(
                kind: "activity",
                payload: .object([
                    "id": .string(id), "kind": .string(activity.kind.rawValue),
                    "title": .string(activity.title),
                    "detail": activity.detail.map(JSONValue.string) ?? .null,
                    "complete": .bool(false),
                ]))
            try? await Task.sleep(for: .milliseconds(250))
            apply(
                kind: "activity",
                payload: .object([
                    "id": .string(id), "kind": .string(activity.kind.rawValue),
                    "title": .string(activity.title),
                    "detail": activity.detail.map(JSONValue.string) ?? .null,
                    "complete": .bool(true),
                ]))
        }

        let response = SpikeCorpus.responses[turnIndex % SpikeCorpus.responses.count]
        for chunk in SpikeCorpus.tokenize(response) {
            guard running, !Task.isCancelled else { return }
            apply(kind: "textDelta", payload: .string(chunk))
            await tick()
        }
        apply(kind: "turnFinished", payload: .object(["success": .bool(true)]))
    }

    private func tick() async {
        try? await Task.sleep(for: .milliseconds(Int(1000.0 / max(1, tokensPerSecond))))
    }

    /// `SequencedEvent` has no public memberwise init, so events round-trip
    /// through JSON — which also mirrors what the wire path really does.
    private func apply(kind: String, payload: JSONValue) {
        sequence += 1
        let envelope: JSONValue = .object([
            "sessionId": .string(sessionId.uuidString),
            "runtimeId": .string(runtimeId.uuidString),
            "epoch": .string(epoch.uuidString),
            "sequence": .int(Int64(sequence)),
            "event": .object(["kind": .string(kind), "payload": payload]),
        ])
        guard
            let data = try? JSONEncoder().encode(envelope),
            let event = try? JSONDecoder().decode(SequencedEvent.self, from: data)
        else { return }
        model.apply(event)
    }
}

// MARK: - Content corpus

enum SpikeCorpus {
    static let prompts = [
        "Refactor the session store so replay cursors survive reconnects.",
        "Why does the transcript jump when a code block finishes streaming?",
        "Add a settings page for notification preferences and wire it up.",
        "Walk me through the connection supervisor's backoff behavior.",
    ]

    static let reasoning = [
        "The user wants replay cursors preserved across reconnects. The current store drops them on disconnect because the supervisor tears down state. I should hoist the cursor map above the connection lifecycle and thread it through hello's resumeFrom.",
        "The jump likely comes from the code block's height changing when highlighting lands. If the row is inside a lazy stack, a late height change below the viewport shifts the anchor. I need to check whether highlight application is deferred past fence close.",
        "A settings page needs a storage model first. UserDefaults is fine for booleans; the notification authorization state has to be read asynchronously, so the view model needs an async load path.",
        "Backoff starts at 500ms and doubles to a 30s cap with jitter. Path changes reset it. I should explain retryImmediately and how suspend interacts with the pending timer.",
    ]

    static let responses = [
        """
        The cursor map now lives on the **client**, not the connection. Three changes land this:

        1. `ReplayCursorStore` — a new actor keyed by `sessionId`, updated on every `SequencedEvent`.
        2. `ConnectionSupervisor` passes `resumeFrom:` from that store on every `hello`, so a reconnect replays only what the phone missed.
        3. The store is *in-memory only* — cursors deliberately do not persist across launches, matching the pairing decision.

        ```swift
        actor ReplayCursorStore {
            private var cursors: [UUID: ReplayCursor] = [:]

            func advance(_ event: SequencedEvent) {
                cursors[event.sessionId] = ReplayCursor(
                    runtimeId: event.runtimeId,
                    epoch: event.epoch,
                    sequence: event.sequence)
            }

            func snapshot() -> [ReplayCursor] { Array(cursors.values) }
        }
        ```

        One caveat: the daemon's journal is a bounded ring, so a *stale* cursor must degrade to a full refetch — that's the `stale-cursor` path tracked on the map.
        """,
        """
        Found it. The jump is a **two-phase height change** on fence close:

        - While streaming, the code block renders as plain monospaced text.
        - When the fence closes, highlighting swaps in a styled view whose line height differs by ~0.5pt per line.

        On a 40-line block that's a ~20pt shift, and because the row sits *above* the bottom anchor, the whole viewport slides. Two fixes, in order of preference:

        1. Reserve the final line height up front — render un-highlighted text with the *same* font metrics the highlighter uses (`SF Mono 13/1.4`), so the swap is paint-only.
        2. If metrics can't match, pin the scroll offset around the swap: read `contentOffset`, apply, restore in the same transaction.

        Fix 1 is the right one — see `HighlightMetrics` in the diff. The jump is gone on a 600-row transcript with three streaming fences.
        """,
        """
        Settings page is in. Structure:

        | Piece | Role |
        |---|---|
        | `NotificationSettings` | `@Observable` model over UserDefaults |
        | `NotificationSettingsView` | the form, three toggles + status row |
        | `AuthorizationBanner` | shown when notifications are denied system-wide |

        The toggles gate the three attention events — *turn finished*, *permission*, *question* — matching the notifications decision. The authorization state loads asynchronously on appear:

        ```swift
        .task {
            status = await UNUserNotificationCenter.current()
                .notificationSettings().authorizationStatus
        }
        ```

        Denied state shows the banner with a deep link to the app's system settings page rather than a dead toggle.
        """,
        """
        The supervisor's backoff, end to end:

        1. **First failure** schedules a retry at `500ms`, doubling per attempt: 0.5s, 1s, 2s … capped at `30s`, each with ±20% jitter so herds of clients don't sync.
        2. **`retryImmediately()`** cancels the pending timer and dials now — called on foreground and on `NWPathMonitor` path changes.
        3. **`suspend()`** cancels the timer *and* the socket without touching the attempt counter, so the next resume continues the schedule rather than restarting it.
        4. A successful `hello` resets the counter to zero.

        The subtle part is candidate failover: each attempt tries the *last-good* endpoint first, then the remaining candidates in order, so a phone moving between Wi-Fi and Tailscale converges in one attempt instead of waiting out a full backoff cycle per address.
        """,
    ]

    static func activities(turn: Int) -> [ActivityItem] {
        let sets: [[(ActivityKind, String, String?)]] = [
            [
                (.search, "Searching for replay cursor usage", "grep resumeFrom"),
                (.fileRead, "Reading ConnectionSupervisor.swift", nil),
                (.fileChange, "Editing ReplayCursorStore.swift", "+48 -3"),
            ],
            [
                (.fileRead, "Reading transcript row builder", nil),
                (.command, "Running row-height probe", "swift test --filter Metrics"),
            ],
            [
                (.fileChange, "Creating NotificationSettingsView.swift", "+120"),
                (.command, "Building", "xcodebuild -scheme Shidou"),
            ],
            [
                (.fileRead, "Reading ConnectionSupervisor.swift", nil)
            ],
        ]
        return sets[turn % sets.count].map { kind, title, detail in
            ActivityItem(kind: kind, title: title, detail: detail, complete: true)
        }
    }

    /// Split text into word-ish streaming chunks (2–3 words each), keeping
    /// whitespace so concatenation reproduces the source exactly.
    static func tokenize(_ text: String) -> [String] {
        var chunks: [String] = []
        var current = ""
        var words = 0
        for character in text {
            current.append(character)
            if character == " " || character == "\n" {
                words += 1
                if words >= 2 + (chunks.count % 2) {
                    chunks.append(current)
                    current = ""
                    words = 0
                }
            }
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks
    }
}
