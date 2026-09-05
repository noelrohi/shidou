import Foundation
import ShidouProtocol
import XCTest

@testable import ShidouSession

final class TranscriptPresentationTests: XCTestCase {
    private let turnId = UUID()

    private func session(
        status: SessionStatus = .idle,
        messages: [Message],
        blocks: [TranscriptBlock] = [],
        turns: [AgentTurn] = []
    ) -> AgentSession {
        AgentSession(
            projectId: UUID(),
            provider: .claude,
            status: status,
            createdAt: 0,
            updatedAt: 0,
            messages: messages,
            transcriptBlocks: blocks,
            turns: turns
        )
    }

    private func activity(_ title: String, complete: Bool = true) -> ActivityItem {
        ActivityItem(kind: .command, title: title, complete: complete)
    }

    private func kinds(_ rows: [TranscriptRow]) -> [String] {
        rows.map { row in
            switch row {
            case .fold: return "fold"
            case .activities: return "activities"
            case .message: return "message"
            case .changed: return "changed"
            case .working: return "working"
            }
        }
    }

    func testRowsInterleaveMessagesAndActivityBlocksInOrder() {
        let messages = [
            Message(turnId: turnId, role: .user, content: "do it", createdAt: 1),
            Message(turnId: turnId, role: .assistant, content: "done", createdAt: 3),
        ]
        let rows = TranscriptPresentation.rows(session(
            // A running turn folds nothing, so the raw order is visible.
            status: .working,
            messages: messages,
            blocks: [TranscriptBlock(afterMessage: 1, turnId: turnId, activities: [activity("Run")])],
            turns: [AgentTurn(id: turnId, turnCount: 1, status: .running, startedAt: 1)]
        ))
        XCTAssertEqual(kinds(rows), ["message", "activities", "message", "working"])
    }

    /// A settled turn's work collapses behind one row; the answer stays out.
    func testSettledTurnWorkFoldsAndExpands() {
        let messages = [
            Message(turnId: turnId, role: .user, content: "do it", createdAt: 1),
            Message(turnId: turnId, role: .assistant, content: "answer", createdAt: 4),
        ]
        let subject = session(
            messages: messages,
            blocks: [TranscriptBlock(afterMessage: 1, turnId: turnId, activities: [activity("Run")])],
            turns: [
                AgentTurn(id: turnId, turnCount: 1, status: .completed, startedAt: 1, completedAt: 4)
            ]
        )
        XCTAssertEqual(kinds(TranscriptPresentation.rows(subject)), ["message", "fold", "message"])
        XCTAssertEqual(
            kinds(TranscriptPresentation.rows(subject, expandedTurns: [turnId])),
            ["message", "fold", "activities", "message"]
        )
    }

    func testTheWorkingRowOnlyAppearsWhileATurnRuns() {
        let running = session(
            status: .working,
            messages: [Message(turnId: turnId, role: .user, content: "go", createdAt: 1)],
            turns: [AgentTurn(id: turnId, turnCount: 1, status: .running, startedAt: 7)]
        )
        guard case .working(let startedAt) = TranscriptPresentation.rows(running).last else {
            return XCTFail("a running turn ends with the working row")
        }
        XCTAssertEqual(startedAt, 7)

        let idle = session(
            messages: [Message(turnId: turnId, role: .user, content: "go", createdAt: 1)],
            turns: [AgentTurn(id: turnId, turnCount: 1, status: .completed, startedAt: 7, completedAt: 8)]
        )
        XCTAssertFalse(kinds(TranscriptPresentation.rows(idle)).contains("working"))
    }

    func testWorkspaceCheckpointWithoutAnswerDoesNotCreateRecordedEdits() {
        var turn = AgentTurn(id: turnId, turnCount: 1, status: .completed, startedAt: 1, completedAt: 2)
        turn.checkpoint = try? JSONDecoder().decode(
            Checkpoint.self,
            from: Data(#"""
                {"turn_count":1,"git_ref":"refs/shidou/x","status":"ready",
                 "files":[{"path":"src/limiter.rs","additions":4,"deletions":1}],
                 "additions":4,"deletions":1,"created_at":2}
                """#.utf8)
        )
        let rows = TranscriptPresentation.rows(session(
            messages: [
                Message(turnId: turnId, role: .user, content: "edit it", createdAt: 1),
                Message(turnId: turnId, role: .assistant, content: "  ", createdAt: 2),
            ],
            turns: [turn]
        ))
        XCTAssertFalse(kinds(rows).contains("changed"))
    }

    func testWorkspaceCheckpointDoesNotAttachToAnswer() throws {
        var turn = AgentTurn(id: turnId, turnCount: 1, status: .completed, startedAt: 1, completedAt: 2)
        turn.checkpoint = try JSONDecoder().decode(
            Checkpoint.self,
            from: Data(#"""
                {"turn_count":1,"git_ref":"refs/shidou/x","status":"ready",
                 "files":[{"path":"a.rs","additions":1,"deletions":0}],
                 "additions":1,"deletions":0,"created_at":2}
                """#.utf8)
        )
        let rows = TranscriptPresentation.rows(session(
            messages: [
                Message(turnId: turnId, role: .user, content: "edit it", createdAt: 1),
                Message(turnId: turnId, role: .assistant, content: "Edited it.", createdAt: 2),
            ],
            turns: [turn]
        ))
        XCTAssertFalse(kinds(rows).contains("changed"))
        let attached = rows.contains { row in
            if case .message(_, let message) = row { return message.recordedEdits != nil }
            return false
        }
        XCTAssertFalse(attached)
    }

    /// The footer's value is the whole visible answer, not the final chunk, so
    /// copying a multi-part response copies all of it.
    func testTheResponseFooterCarriesTheWholeAnswer() {
        let footers = TranscriptPresentation.assistantResponseFooters(session(
            messages: [
                Message(turnId: turnId, role: .user, content: "go", createdAt: 1),
                Message(turnId: turnId, role: .assistant, content: "first", createdAt: 2),
                Message(turnId: turnId, role: .assistant, content: "second", createdAt: 3),
            ],
            turns: [
                AgentTurn(id: turnId, turnCount: 1, status: .completed, startedAt: 1, completedAt: 9)
            ]
        ))
        XCTAssertEqual(footers[2]?.content, "first\n\nsecond")
        XCTAssertEqual(footers[2]?.timestamp, 9)
        XCTAssertNil(footers[1], "only the terminal assistant message carries the footer")
    }

    func testRowIdentitiesAreUnique() {
        let rows = TranscriptPresentation.rows(session(
            messages: [
                Message(turnId: turnId, role: .user, content: "go", createdAt: 1),
                Message(turnId: turnId, role: .assistant, content: "ok", createdAt: 2),
            ],
            blocks: [
                TranscriptBlock(afterMessage: 1, turnId: turnId, activities: [activity("a")]),
                TranscriptBlock(afterMessage: 1, turnId: turnId, activities: [activity("b")]),
            ],
            turns: [AgentTurn(id: turnId, turnCount: 1, status: .running, startedAt: 1)]
        ))
        XCTAssertEqual(Set(rows.map(\.id)).count, rows.count)
    }

    // MARK: - Fork and rewind

    private func historySession(
        status: SessionStatus = .idle,
        providerCursor: JSONValue? = .object(["provider": .string("claude")]),
        turns: [AgentTurn],
        messages: [Message]
    ) -> AgentSession {
        AgentSession(
            projectId: UUID(),
            provider: .claude,
            status: status,
            createdAt: 0,
            updatedAt: 0,
            providerCursor: providerCursor,
            messages: messages,
            turns: turns
        )
    }

    func testForkIsOfferedOnASettledAnswerWithAProviderCursor() {
        let turn = AgentTurn(
            id: turnId, turnCount: 2, status: .completed, providerTurnStarted: true, startedAt: 1
        )
        let message = Message(turnId: turnId, role: .assistant, content: "done", createdAt: 2)
        let session = historySession(turns: [turn], messages: [message])
        XCTAssertEqual(
            TranscriptPresentation.responseForkTurnCount(session, message: message, turn: turn), 2
        )
    }

    /// A cursor belonging to a provider the task no longer runs cannot be
    /// replayed, so the fork is not offered rather than offered and broken.
    func testForkIsWithheldWhenTheCursorBelongsToAnotherProvider() {
        let turn = AgentTurn(
            id: turnId, turnCount: 2, status: .completed, providerTurnStarted: true, startedAt: 1
        )
        let message = Message(turnId: turnId, role: .assistant, content: "done", createdAt: 2)
        let session = historySession(
            providerCursor: .object(["provider": .string("codex")]),
            turns: [turn],
            messages: [message]
        )
        XCTAssertNil(
            TranscriptPresentation.responseForkTurnCount(session, message: message, turn: turn)
        )
    }

    func testForkIsWithheldWhileTheTaskIsStillWorking() {
        let turn = AgentTurn(
            id: turnId, turnCount: 2, status: .completed, providerTurnStarted: true, startedAt: 1
        )
        let message = Message(turnId: turnId, role: .assistant, content: "done", createdAt: 2)
        let session = historySession(status: .working, turns: [turn], messages: [message])
        XCTAssertNil(
            TranscriptPresentation.responseForkTurnCount(session, message: message, turn: turn)
        )
    }

    func testRewindNeedsTheCheckpointTakenBeforeThatPrompt() {
        let turn = AgentTurn(
            id: turnId, turnCount: 1, status: .completed, providerTurnStarted: true, startedAt: 1
        )
        let message = Message(turnId: turnId, role: .user, content: "do it", createdAt: 1)
        let session = historySession(turns: [turn], messages: [message])
        XCTAssertEqual(
            TranscriptPresentation.userMessageRewindTurnCount(
                session, message: message, retainedTurnCounts: [0]
            ),
            1
        )
        XCTAssertNil(
            TranscriptPresentation.userMessageRewindTurnCount(
                session, message: message, retainedTurnCounts: []
            ),
            "no ref means nothing to restore"
        )
    }

    /// Rolling back turns the provider already ran needs a cursor to resume
    /// from; without one the transcript would move and the provider's own
    /// history would not.
    func testRewindIsWithheldWhenStartedTurnsCannotBeRolledBack() {
        let turn = AgentTurn(
            id: turnId, turnCount: 1, status: .completed, providerTurnStarted: true, startedAt: 1
        )
        let message = Message(turnId: turnId, role: .user, content: "do it", createdAt: 1)
        let session = historySession(providerCursor: nil, turns: [turn], messages: [message])
        XCTAssertNil(
            TranscriptPresentation.userMessageRewindTurnCount(
                session, message: message, retainedTurnCounts: [0]
            )
        )
    }

    func testRowsCarryForkAndRewindCounts() {
        let turn = AgentTurn(
            id: turnId, turnCount: 1, status: .completed, providerTurnStarted: true, startedAt: 1
        )
        let messages = [
            Message(turnId: turnId, role: .user, content: "do it", createdAt: 1),
            Message(turnId: turnId, role: .assistant, content: "done", createdAt: 2),
        ]
        let rows = TranscriptPresentation.rows(
            historySession(turns: [turn], messages: messages),
            retainedTurnCounts: [0]
        )
        let messageRows: [MessageRow] = rows.compactMap { row in
            if case .message(_, let messageRow) = row { return messageRow }
            return nil
        }
        XCTAssertEqual(messageRows.first?.rewindTurnCount, 1)
        XCTAssertNil(messageRows.first?.forkTurnCount, "a prompt is not forkable")
        XCTAssertEqual(messageRows.last?.forkTurnCount, 1)
        XCTAssertNil(messageRows.last?.rewindTurnCount, "an answer is not rewindable")
    }

}

final class TranscriptLinksTests: XCTestCase {
    func testWorkspacePathsBecomeProjectFiles() {
        let route = TranscriptLinks.route(target: "/src/shidou/limiter.rs:42", workspace: "/src/shidou")
        XCTAssertEqual(route, .projectFile(path: "limiter.rs", line: 42))
    }

    func testPathsOutsideTheWorkspaceStayRemote() {
        let route = TranscriptLinks.route(target: "/etc/hosts", workspace: "/src/shidou")
        XCTAssertEqual(route, .remoteFile(path: "/etc/hosts", line: nil))
    }

    func testFileURLsAndFragmentsResolve() {
        XCTAssertEqual(
            TranscriptLinks.route(target: "file:///src/a%20b.rs#L7", workspace: "/src"),
            .projectFile(path: "a b.rs", line: 7)
        )
        XCTAssertEqual(
            TranscriptLinks.route(target: "/src/a.rs:12:4", workspace: "/src"),
            .projectFile(path: "a.rs", line: 12)
        )
    }

    func testWebURLsAreExternal() {
        XCTAssertEqual(TranscriptLinks.route(target: "https://example.com"), .external)
        XCTAssertEqual(TranscriptLinks.route(target: "relative/path.rs"), .external)
    }

    func testDotSegmentsResolveWithoutTouchingTheFilesystem() {
        XCTAssertEqual(
            TranscriptLinks.route(target: "/src/shidou/./nested/../limiter.rs", workspace: "/src/shidou"),
            .projectFile(path: "limiter.rs", line: nil)
        )
    }
}

final class TranscriptFindTests: XCTestCase {
    private func rows(_ texts: [String]) -> [TranscriptRow] {
        texts.enumerated().map { index, text in
            .message(key: "m\(index)", MessageRow(
                message: Message(role: .assistant, content: text, createdAt: 0),
                index: index,
                isFirst: index == 0,
                startsFollowUp: false
            ))
        }
    }

    func testEveryOccurrenceIsCountedAcrossRows() {
        let result = TranscriptFind.matches(
            in: rows(["limiter and limiter", "nothing", "Limiter"]), query: "limiter"
        )
        XCTAssertEqual(result.matches.count, 3)
        XCTAssertEqual(result.matches.map(\.rowIndex), [0, 0, 2])
        XCTAssertEqual(result.matches.map(\.ordinal), [0, 1, 0])
        XCTAssertFalse(result.limited)
    }

    func testAnEmptyQueryMatchesNothing() {
        XCTAssertTrue(TranscriptFind.matches(in: rows(["a"]), query: "").matches.isEmpty)
    }

    func testTheMatchLimitIsReportedRatherThanHidden() {
        let result = TranscriptFind.matches(
            in: rows([String(repeating: "ab", count: 50)]), query: "a", limit: 10
        )
        XCTAssertEqual(result.matches.count, 10)
        XCTAssertTrue(result.limited)
    }

    func testSteppingWrapsAtBothEnds() {
        XCTAssertEqual(TranscriptFind.step(current: nil, count: 3, backward: false), 0)
        XCTAssertEqual(TranscriptFind.step(current: nil, count: 3, backward: true), 2)
        XCTAssertEqual(TranscriptFind.step(current: 2, count: 3, backward: false), 0)
        XCTAssertEqual(TranscriptFind.step(current: 0, count: 3, backward: true), 2)
        XCTAssertNil(TranscriptFind.step(current: 0, count: 0, backward: false))
    }

    /// A streaming append renumbers every match after the tail. Holding the
    /// position by row identity is what stops find from jumping while the
    /// answer is still arriving.
    func testTheCurrentMatchSurvivesARebuild() {
        let previous = TranscriptMatch(rowIndex: 5, rowKey: "m5", ordinal: 1)
        let rebuilt = [
            TranscriptMatch(rowIndex: 0, rowKey: "m0", ordinal: 0),
            TranscriptMatch(rowIndex: 6, rowKey: "m5", ordinal: 0),
            TranscriptMatch(rowIndex: 6, rowKey: "m5", ordinal: 1),
        ]
        XCTAssertEqual(TranscriptFind.reconcile(previous: previous, matches: rebuilt), 2)
    }

    func testActivityOutputIsSearchable() {
        var activity = ActivityItem(kind: .command, title: "Run", complete: true)
        activity.output = "error: limiter overflow"
        let row = TranscriptRow.activities(
            key: "b0",
            block: TranscriptBlock(afterMessage: 0, turnId: nil, activities: [activity]),
            isLive: false
        )
        XCTAssertEqual(TranscriptFind.matches(in: [row], query: "overflow").matches.count, 1)
    }
}
