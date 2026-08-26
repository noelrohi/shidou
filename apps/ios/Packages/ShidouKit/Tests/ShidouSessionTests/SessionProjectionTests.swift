import Foundation
import XCTest

@testable import ShidouProtocol
@testable import ShidouSession

/// Port of `apps/web/src/lib/event-reducer.test.ts`. Keep the cases in sync:
/// both clients persist the projection they compute, so behavioral drift
/// between the two reducers corrupts shared sessions.
final class SessionProjectionTests: XCTestCase {
    private let sessionId = UUID(uuidString: "00000000-0000-4000-8000-0000000000aa")!
    private let runtimeId = UUID(uuidString: "00000000-0000-4000-8000-0000000000bb")!
    private let epoch = UUID(uuidString: "00000000-0000-4000-8000-0000000000cc")!
    private let projectId = UUID(uuidString: "00000000-0000-4000-8000-0000000000dd")!
    private let turnId = UUID(uuidString: "00000000-0000-4000-8000-0000000000ee")!
    private let messageId = UUID(uuidString: "00000000-0000-4000-8000-0000000000ff")!

    private final class Counter: @unchecked Sendable {
        var value = 0
        func next() -> UUID {
            value += 1
            return UUID(uuidString: String(format: "00000000-0000-4000-8000-%012d", value))!
        }
    }

    private func makeClock() -> ReducerClock {
        let counter = Counter()
        return ReducerClock(
            nowSeconds: { 200 },
            nowMillis: { 200_000 },
            randomUUID: { counter.next() }
        )
    }

    private func event(_ kind: String, _ payload: JSONValue, sequence: UInt64 = 1) -> SequencedEvent {
        SequencedEvent(
            sessionId: sessionId, runtimeId: runtimeId, epoch: epoch,
            sequence: sequence, event: WireDriverEvent(kind: kind, payload: payload)
        )
    }

    private func runningSession() -> AgentSession {
        AgentSession(
            id: sessionId,
            projectId: projectId,
            provider: .codex,
            status: .connecting,
            createdAt: 100,
            updatedAt: 100,
            messages: [
                Message(id: messageId, turnId: turnId, role: .user, content: "Go", createdAt: 100)
            ],
            turns: [
                AgentTurn(id: turnId, turnCount: 1, status: .running, startedAt: 100)
            ]
        )
    }

    private func apply(
        _ session: AgentSession, _ kind: String, _ payload: JSONValue, clock: ReducerClock
    ) -> AgentSession {
        reduceRuntimeEvent(session, event(kind, payload), clock: clock).session
    }

    func testPreservesEventOrderAcrossReasoningToolsAndText() {
        let clock = makeClock()
        var session = runningSession()
        session = apply(session, "reasoningDelta", "Thinking", clock: clock)
        session = apply(
            session, "richActivity",
            [
                "id": "10000000-0000-4000-8000-000000000001",
                "source_id": "tool-1",
                "kind": "fileRead",
                "title": "Read file",
                "detail": "src/app.rs",
                "failed": false,
                "complete": true,
            ],
            clock: clock
        )
        session = apply(session, "textDelta", "Done", clock: clock)
        session = apply(session, "textDelta", ".", clock: clock)

        let activities = session.transcriptBlocks[0].activities
        XCTAssertEqual(activities.count, 2)
        XCTAssertEqual(activities[0].reasoning?.content, "Thinking")
        XCTAssertTrue(activities[0].complete)
        XCTAssertEqual(activities[1].sourceId, "tool-1")
        XCTAssertEqual(activities[1].title, "Read file")
        XCTAssertEqual(session.messages.last?.content, "Done.")
    }

    func testSettlesActiveTurnAndFinalizesStreamingOutput() {
        let clock = makeClock()
        var session = runningSession()
        session = apply(session, "textDelta", "Ready", clock: clock)
        let result = reduceRuntimeEvent(
            session, event("turnFinished", ["success": true, "summary": nil]), clock: clock
        )

        XCTAssertTrue(result.settled)
        XCTAssertEqual(result.session.status, .idle)
        XCTAssertEqual(result.session.turns[0].status, .completed)
        XCTAssertEqual(result.session.messages.last?.streaming, false)
    }

    func testProcessExitDoesNotFailACompletedSession() {
        let clock = makeClock()
        var session = runningSession()
        session = reduceRuntimeEvent(
            session, event("turnFinished", ["success": true, "summary": nil]), clock: clock
        ).session
        let result = reduceRuntimeEvent(session, event("processExited", .null), clock: clock)

        XCTAssertEqual(result.session.status, .idle)
        XCTAssertEqual(result.session.turns[0].status, .completed)
        XCTAssertFalse(result.settled)
        XCTAssertTrue(result.removeRuntime)
    }

    func testStoresDaemonSequenceInCursor() {
        let clock = makeClock()
        let result = reduceRuntimeEvent(
            runningSession(), event("textDelta", "hello", sequence: 42), clock: clock
        )
        XCTAssertEqual(
            result.session.runtimeEventCursor,
            RuntimeEventCursor(runtimeId: runtimeId, epoch: epoch, sequence: 42)
        )
    }

    func testRecordsClaudeResumePositionOnActiveTurn() {
        let clock = makeClock()
        let result = reduceRuntimeEvent(
            runningSession(),
            event("connected", [
                "provider": "claude",
                "sessionId": "provider-session",
                "resumeAt": "provider-message",
            ]),
            clock: clock
        )
        XCTAssertEqual(result.session.turns[0].providerResumeAt, "provider-message")
    }

    func testIgnoresLateOutputAndPermissionsAfterSettle() {
        let clock = makeClock()
        var session = reduceRuntimeEvent(
            runningSession(), event("turnFinished", ["success": true, "summary": nil]), clock: clock
        ).session
        let messageCount = session.messages.count
        session = apply(session, "textDelta", "late output", clock: clock)
        session = apply(
            session, "richActivity",
            [
                "id": "10000000-0000-4000-8000-000000000002",
                "source_id": "late-tool", "kind": "tool", "title": "Late tool",
                "failed": false, "complete": true,
            ],
            clock: clock
        )
        let permission = reduceRuntimeEvent(
            session,
            event("permission", ["requestId": "late", "title": "Late", "detail": "", "options": []]),
            clock: clock
        )

        XCTAssertEqual(permission.session.messages.count, messageCount)
        XCTAssertEqual(permission.session.transcriptBlocks.count, 0)
        XCTAssertEqual(permission.session.status, .idle)
        XCTAssertNil(permission.permission)
    }

    func testSurfacesUserInputAndClearsOnSettle() {
        let clock = makeClock()
        let requested = reduceRuntimeEvent(
            runningSession(),
            event("userInputRequested", [
                "requestId": "question-request",
                "questions": [
                    [
                        "id": "deployment",
                        "header": "Environment",
                        "question": "Where should this deploy?",
                        "options": [["label": "Preview", "description": "Create a preview deployment"]],
                        "multiSelect": false,
                    ]
                ],
            ]),
            clock: clock
        )

        XCTAssertEqual(requested.session.status, .waiting)
        guard case .some(.some(let userInput)) = requested.userInput else {
            return XCTFail("expected a pending user input")
        }
        XCTAssertEqual(userInput.questions[0].id, "deployment")
        XCTAssertEqual(userInput.questions[0].options[0].label, "Preview")

        let settled = reduceRuntimeEvent(
            requested.session, event("turnFinished", ["success": true, "summary": nil]), clock: clock
        )
        guard case .some(.none) = settled.userInput else {
            return XCTFail("expected the user input to clear")
        }
    }

    func testKeepsProviderErrorWhenWorkingRuntimeExits() {
        let clock = makeClock()
        var session = apply(runningSession(), "turnStarted", .null, clock: clock)
        let errored = reduceRuntimeEvent(session, event("error", "provider exploded"), clock: clock)
        XCTAssertEqual(errored.session.status, .working)
        session = reduceRuntimeEvent(
            errored.session, event("processExited", .null), clock: clock,
            processExitError: errored.error
        ).session

        XCTAssertEqual(session.status, .failed)
        XCTAssertEqual(session.messages.last?.content, "provider exploded")
    }

    func testStartupErrorIsNotDuplicatedOnExit() {
        let clock = makeClock()
        let errored = reduceRuntimeEvent(
            runningSession(), event("error", "could not start provider"), clock: clock
        )
        XCTAssertEqual(errored.session.status, .failed)
        XCTAssertEqual(errored.session.messages.last?.content, "could not start provider")

        let exited = reduceRuntimeEvent(
            errored.session, event("processExited", .null), clock: clock,
            processExitError: errored.error
        )
        XCTAssertEqual(exited.session.messages.filter { $0.role == .assistant }.count, 1)
    }

    func testReplayDeduplication() {
        var session = runningSession()
        XCTAssertFalse(runtimeEventAlreadyApplied(session: session, event: event("textDelta", "x", sequence: 5)))
        session.runtimeEventCursor = RuntimeEventCursor(runtimeId: runtimeId, epoch: epoch, sequence: 5)
        XCTAssertTrue(runtimeEventAlreadyApplied(session: session, event: event("textDelta", "x", sequence: 5)))
        XCTAssertTrue(runtimeEventAlreadyApplied(session: session, event: event("textDelta", "x", sequence: 4)))
        XCTAssertFalse(runtimeEventAlreadyApplied(session: session, event: event("textDelta", "x", sequence: 6)))
        let otherEpoch = UUID()
        session.runtimeEventCursor = RuntimeEventCursor(runtimeId: runtimeId, epoch: otherEpoch, sequence: 9)
        XCTAssertFalse(runtimeEventAlreadyApplied(session: session, event: event("textDelta", "x", sequence: 5)))
    }
}
