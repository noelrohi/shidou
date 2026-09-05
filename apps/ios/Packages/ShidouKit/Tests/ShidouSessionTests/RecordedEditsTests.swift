import Foundation
import Observation
import ShidouProtocol
import XCTest
@testable import ShidouSession

final class RecordedEditsTests: XCTestCase {
    private func edit(_ path: String, additions: UInt64? = 2, deletions: UInt64? = 1,
                      failed: Bool = false, complete: Bool = true,
                      kind: ActivityKind = .fileChange,
                      diff: String? = "@@ -1 +1 @@\n-old\n+new") throws -> ActivityItem {
        let change = try JSONDecoder().decode(ActivityFileChange.self, from: JSONSerialization.data(
            withJSONObject: ["path": path, "additions": additions as Any? ?? NSNull(),
                             "deletions": deletions as Any? ?? NSNull(), "diff": diff as Any? ?? NSNull()]
        ))
        return ActivityItem(kind: kind, title: "Edit", failed: failed, complete: complete, fileChanges: [change])
    }

    private func session(_ turns: [AgentTurn], _ blocks: [TranscriptBlock], answer: Bool = true) -> AgentSession {
        AgentSession(projectId: UUID(), provider: .claude, createdAt: 0, updatedAt: 0,
                     messages: turns.map {
                         Message(turnId: $0.id, role: answer ? .assistant : .user, content: "text", createdAt: 0)
                     }, transcriptBlocks: blocks, turns: turns)
    }

    func testOnlySuccessfulCompletedFileChangesFromExactTurn() throws {
        var turn = AgentTurn(turnCount: 1, status: .completed, startedAt: 0)
        turn.checkpoint = try JSONDecoder().decode(Checkpoint.self, from: Data(#"{"turn_count":1,"git_ref":"ref","status":"ready","files":[{"path":"unrelated","additions":99,"deletions":99}],"additions":99,"deletions":99,"created_at":0}"#.utf8))
        let other = AgentTurn(turnCount: 2, status: .completed, startedAt: 0)
        let good = try edit("own")
        let subject = session([turn, other], [
            TranscriptBlock(afterMessage: 0, turnId: other.id, activities: [try edit("other")]),
            TranscriptBlock(afterMessage: 0, turnId: turn.id, activities: [
                good, try edit("failed", failed: true), try edit("incomplete", complete: false),
                try edit("command", kind: .command),
            ]),
            TranscriptBlock(afterMessage: 0, turnId: nil, activities: [try edit("unattributed")]),
        ])
        let summaries = RecordedEdits.summaries(in: subject)
        let summary = try XCTUnwrap(summaries[turn.id])
        XCTAssertEqual(summary.files.map(\.path), ["own"])
        XCTAssertEqual(summary.activityIds, [good.id])
        XCTAssertEqual(summary.firstRowKey, "block-1")
        XCTAssertEqual(summaries[other.id]?.files.map(\.path), ["other"])
        let rows = TranscriptPresentation.rows(subject, expandedTurns: [turn.id], recordedEdits: summaries)
        let attached = rows.compactMap { row -> RecordedEdits? in
            if case .message(_, let message) = row, message.message.turnId == turn.id { return message.recordedEdits }
            return nil
        }
        XCTAssertEqual(attached.first?.files.map(\.path), ["own"])
        XCTAssertTrue(rows.contains { if case .activities(let key, _, _) = $0 { return key == summary.firstRowKey }; return false })
    }

    func testRepeatedEditsSumAndUnknownCountsStayUnknown() throws {
        let turn = AgentTurn(turnCount: 1, status: .completed, startedAt: 0)
        let subject = session([turn], [TranscriptBlock(afterMessage: 0, turnId: turn.id, activities: [
            try edit("known"), try edit("unknown", additions: nil),
            try edit("known", additions: 3, deletions: 4),
            try edit("unknown", additions: 5, deletions: nil), try edit("unknown"),
        ])])
        let summary = try XCTUnwrap(RecordedEdits.summaries(in: subject)[turn.id])
        XCTAssertEqual(summary.files.map(\.path), ["known", "unknown"])
        XCTAssertEqual(summary.files[0].additions, 5)
        XCTAssertEqual(summary.files[0].deletions, 5)
        XCTAssertNil(summary.files[1].additions)
        XCTAssertNil(summary.files[1].deletions)
        XCTAssertNil(summary.additions)
        XCTAssertNil(summary.deletions)
    }

    func testEditsWithoutCheckpointProduceStandaloneCardAndKnownTotals() throws {
        let turn = AgentTurn(turnCount: 1, status: .completed, startedAt: 0)
        let subject = session([turn], [TranscriptBlock(afterMessage: 1, turnId: turn.id,
            activities: [try edit("a"), try edit("a"), try edit("b")])], answer: false)
        guard case .changed(_, let id, let edits) = TranscriptPresentation.rows(subject).last else {
            return XCTFail("Expected standalone recorded edits")
        }
        XCTAssertEqual(id, turn.id)
        XCTAssertEqual(edits.files.count, 2)
        XCTAssertEqual(edits.additions, 6)
        XCTAssertEqual(edits.deletions, 3)
    }

    func testReviewDisclosesRecordedDiffWithoutToolOutput() throws {
        let activity = try edit("own")
        let sections = ActivityPresentation.disclosureSections(activity)
        XCTAssertEqual(sections.map(\.content), ["own\n@@ -1 +1 @@\n-old\n+new"])
        XCTAssertTrue(ActivityPresentation.disclosureSections(try edit("failed", failed: true)).isEmpty)
        XCTAssertTrue(ActivityPresentation.disclosureSections(try edit("running", complete: false)).isEmpty)
    }

    func testMissingAndBlankDiffsHaveExplicitMissingState() throws {
        for diff in [nil, "", " \n\t"] as [String?] {
            let sections = ActivityPresentation.disclosureSections(try edit("own", diff: diff))
            let section = try XCTUnwrap(sections.first)
            XCTAssertEqual(section.kind, .diff)
            XCTAssertEqual(section.content, "own")
            XCTAssertTrue(section.isDiffMissing)
        }
    }

    func testRecordedPatchWhitespaceIsPreserved() throws {
        let patch = "\n @@ -1 +1 @@\n-old \t\n+new  \n\n"
        let section = try XCTUnwrap(ActivityPresentation.disclosureSections(try edit("own", diff: patch)).first)
        XCTAssertEqual(section.content, "own\n" + patch)
        XCTAssertFalse(section.isDiffMissing)
    }

    func testUnknownAdditionsDoNotEraseKnownDeletions() throws {
        let turn = AgentTurn(turnCount: 1, status: .completed, startedAt: 0)
        let subject = session([turn], [TranscriptBlock(afterMessage: 0, turnId: turn.id,
            activities: [try edit("a"), try edit("a", additions: nil)])])
        let summary = try XCTUnwrap(RecordedEdits.summaries(in: subject)[turn.id])
        XCTAssertNil(summary.additions)
        XCTAssertEqual(summary.deletions, 2)
        XCTAssertNil(summary.files[0].additions)
        XCTAssertEqual(summary.files[0].deletions, 2)
    }

    func testPathAndActivityOrderingAndRunningTurnEligibility() throws {
        let turn = AgentTurn(turnCount: 1, status: .running, startedAt: 0)
        let first = try edit("b")
        let second = try edit(" a ")
        let third = try edit("b")
        let fourth = try edit("a")
        let subject = session([turn], [
            TranscriptBlock(afterMessage: 0, turnId: turn.id, activities: [try edit(" \n\t")]),
            TranscriptBlock(afterMessage: 0, turnId: turn.id, activities: [first, second]),
            TranscriptBlock(afterMessage: 1, turnId: turn.id, activities: [third, fourth, try edit("")]),
        ])
        let summary = try XCTUnwrap(RecordedEdits.summaries(in: subject)[turn.id])
        XCTAssertEqual(summary.files.map(\.path), ["b", " a ", "a"])
        XCTAssertEqual(summary.activityIds, [first.id, second.id, third.id, fourth.id])
        XCTAssertEqual(summary.firstRowKey, "block-1")
        XCTAssertEqual(summary.additions, 8)
        XCTAssertEqual(summary.deletions, 4)
        for row in TranscriptPresentation.rows(subject) {
            if case .message(_, let message) = row { XCTAssertNil(message.recordedEdits) }
            if case .changed = row { XCTFail("Running turns do not show cards") }
        }
    }

    func testWhitespaceOnlyEditsHaveNoSummaryOrReviewActivity() throws {
        let turn = AgentTurn(turnCount: 1, status: .completed, startedAt: 0)
        let activity = try edit(" \t")
        let subject = session([turn], [TranscriptBlock(afterMessage: 0, turnId: turn.id, activities: [activity])])
        XCTAssertTrue(RecordedEdits.summaries(in: subject).isEmpty)
        XCTAssertTrue(ActivityPresentation.disclosureSections(activity).isEmpty)
    }

    func testNoEditsHasNoCard() {
        let turn = AgentTurn(turnCount: 1, status: .completed, startedAt: 0)
        let subject = session([turn], [])
        XCTAssertTrue(RecordedEdits.summaries(in: subject).isEmpty)
        for row in TranscriptPresentation.rows(subject) {
            if case .message(_, let message) = row { XCTAssertNil(message.recordedEdits) }
            if case .changed = row { XCTFail("No recorded edits") }
        }
    }

    @MainActor private final class CacheObservation {
        var invalidated = false

        init(_ model: SessionRuntimeModel) {
            withObservationTracking {
                _ = model.recordedEdits
            } onChange: { [weak self] in
                MainActor.assumeIsolated { self?.invalidated = true }
            }
        }
    }

    @MainActor func testTextReasoningAndUsagePublicationsReuseRecordedEdits() throws {
        let turn = AgentTurn(turnCount: 1, status: .running, startedAt: 0)
        var subject = session([turn], [TranscriptBlock(afterMessage: 0, turnId: turn.id,
            activities: [try edit("historical")])])
        subject.status = .working
        let model = SessionRuntimeModel(session: subject)
        let observation = CacheObservation(model)
        let runtimeId = UUID()
        let epoch = UUID()
        let events: [(String, JSONValue)] = [
            ("textDelta", "hello"), ("reasoningDelta", "thinking"),
            ("usageUpdated", ["contextTokens": 42]), ("textDelta", "done"),
        ]
        for (index, event) in events.enumerated() {
            model.beginCatchUp()
            model.apply(SequencedEvent(sessionId: subject.id, runtimeId: runtimeId, epoch: epoch,
                sequence: UInt64(index + 1), event: WireDriverEvent(kind: event.0, payload: event.1)))
            model.endCatchUp()
            XCTAssertFalse(observation.invalidated, event.0)
        }
        XCTAssertEqual(model.session.contextUsage?.tokens, 42)
        XCTAssertTrue(model.session.messages.contains { $0.content == "hello" })
        XCTAssertEqual(model.recordedEdits[turn.id]?.files.map(\.path), ["historical"])
    }

    @MainActor func testActivityInvalidationIsCoalescedAndDuplicateEventsAreIgnored() throws {
        let turn = AgentTurn(turnCount: 1, status: .running, startedAt: 0)
        var subject = session([turn], [])
        subject.status = .working
        let model = SessionRuntimeModel(session: subject)
        var activity = try edit("new")
        activity.sourceId = "edit-1"
        let event = SequencedEvent(sessionId: subject.id, runtimeId: UUID(), epoch: UUID(), sequence: 1,
            event: WireDriverEvent(kind: "richActivity", payload: try .encoding(activity)))
        let observation = CacheObservation(model)
        model.beginCatchUp()
        model.apply(event)
        XCTAssertFalse(observation.invalidated)
        model.endCatchUp()
        XCTAssertTrue(observation.invalidated)
        XCTAssertEqual(model.recordedEdits[turn.id]?.files.map(\.path), ["new"])

        let duplicateObservation = CacheObservation(model)
        model.beginCatchUp()
        XCTAssertNil(model.apply(event))
        model.endCatchUp()
        XCTAssertFalse(duplicateObservation.invalidated)

        // A basic activity can replace a rich file edit by source ID.
        model.beginCatchUp()
        model.apply(SequencedEvent(sessionId: subject.id, runtimeId: event.runtimeId, epoch: event.epoch,
            sequence: 2, event: WireDriverEvent(kind: "activity", payload: [
                "id": "edit-1", "kind": "command", "title": "Run", "complete": true,
            ])))
        model.endCatchUp()
        XCTAssertTrue(model.recordedEdits.isEmpty)
    }

    @MainActor func testSettlementRefreshesCompletedEditEligibility() throws {
        for kind in ["turnFinished", "processExited"] {
            let turn = AgentTurn(turnCount: 1, status: .running, startedAt: 0)
            var subject = session([turn], [TranscriptBlock(afterMessage: 0, turnId: turn.id,
                activities: [try edit("pending", complete: false)])])
            subject.status = .working
            let model = SessionRuntimeModel(session: subject)
            XCTAssertTrue(model.recordedEdits.isEmpty)
            model.apply(SequencedEvent(sessionId: subject.id, runtimeId: UUID(), epoch: UUID(), sequence: 1,
                event: WireDriverEvent(kind: kind, payload: ["success": true])))
            XCTAssertEqual(model.recordedEdits[turn.id]?.files.map(\.path), ["pending"], kind)
        }
    }

    @MainActor func testAcceptedTurnRemapsCachedEditAttribution() throws {
        let provisional = AgentTurn(turnCount: 1, status: .running, startedAt: 0)
        let canonical = AgentTurn(turnCount: 1, status: .running, startedAt: 0)
        let subject = session([provisional], [TranscriptBlock(afterMessage: 0, turnId: provisional.id,
            activities: [try edit("own")])])
        let model = SessionRuntimeModel(session: subject)
        model.beginCatchUp()
        model.apply(SequencedEvent(sessionId: subject.id, runtimeId: UUID(), epoch: UUID(), sequence: 1,
            event: WireDriverEvent(kind: "turnAccepted", payload: [
                "submissionId": try .encoding(provisional.id), "turn": try .encoding(canonical), "messages": [],
            ])))
        model.endCatchUp()
        XCTAssertNil(model.recordedEdits[provisional.id])
        XCTAssertEqual(model.recordedEdits[canonical.id]?.files.map(\.path), ["own"])
    }

    @MainActor func testRuntimeCacheRefreshesOnPublication() throws {
        let turn = AgentTurn(turnCount: 1, status: .completed, startedAt: 0)
        let model = SessionRuntimeModel(session: session([turn], []))
        XCTAssertTrue(model.recordedEdits.isEmpty)
        model.replaceSession(session([turn], [TranscriptBlock(afterMessage: 0, turnId: turn.id,
            activities: [try edit("a")])]))
        XCTAssertEqual(model.recordedEdits[turn.id]?.files.map(\.path), ["a"])
        model.replaceSession(session([turn], []))
        XCTAssertTrue(model.recordedEdits.isEmpty)
    }
}
