import Foundation
import ShidouProtocol
import XCTest

@testable import ShidouSession

final class SessionListPresentationTests: XCTestCase {
    private let projectId = UUID()
    private let now = Date(timeIntervalSince1970: 1_700_000_000)
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        calendar.firstWeekday = 2
        return calendar
    }

    private func session(
        title: String = "Task",
        status: SessionStatus = .idle,
        agoSeconds: TimeInterval = 0,
        started: Bool = true
    ) -> AgentSession {
        let stamp = UInt64(now.timeIntervalSince1970 - agoSeconds)
        return AgentSession(
            title: title,
            projectId: projectId,
            provider: .claude,
            status: status,
            createdAt: stamp,
            updatedAt: stamp,
            lastReplyAt: started ? stamp : nil,
            messages: started ? [Message(role: .user, content: "hi", createdAt: stamp)] : []
        )
    }

    private var project: Project {
        Project(id: projectId, name: "shidou", path: "/src/shidou", createdAt: 0)
    }

    /// A draft with no prompt is the composer's business. Showing it would put
    /// an empty row at the top of the list every time New Task was abandoned.
    func testOnlyStartedSessionsAppear() {
        let sections = SessionListPresentation.sections(
            sessions: [session(), session(title: "Draft", started: false)],
            projects: [project],
            now: now,
            calendar: calendar
        )
        XCTAssertEqual(sections.flatMap(\.items).map(\.session.title), ["Task"])
    }

    func testSectionsAreRecencyBucketsNewestFirst() {
        let sections = SessionListPresentation.sections(
            sessions: [
                session(title: "old", agoSeconds: 400 * 86_400),
                session(title: "now", agoSeconds: 60),
                session(title: "yesterday", agoSeconds: 86_400),
            ],
            projects: [project],
            now: now,
            calendar: calendar
        )
        XCTAssertEqual(sections.map(\.group), [.today, .yesterday, .more])
        XCTAssertEqual(sections[0].items.map(\.session.title), ["now"])
    }

    func testRowsCarryProjectAndBranch() {
        var worktree = session()
        worktree.workspace = .worktree(path: "/src/shidou-wt", branch: "feature/x")
        let item = SessionListPresentation.sections(
            sessions: [worktree], projects: [project], now: now, calendar: calendar
        ).first?.items.first

        XCTAssertEqual(item?.projectName, "shidou")
        XCTAssertEqual(item?.projectPath, "/src/shidou")
        XCTAssertEqual(item?.branch, "feature/x")
    }

    /// The list marks blocked sessions because they are the only rows where
    /// nothing happens until the user comes back.
    func testWaitingSessionsAreMarked() {
        let waiting = session(status: .waiting)
        let items = SessionListPresentation.sections(
            sessions: [waiting, session()], projects: [project], now: now, calendar: calendar
        ).flatMap(\.items)
        XCTAssertEqual(items.filter(\.isWaiting).count, 1)
    }

    func testRowStatusPrefersTheRunningTurnOverTheLastReply() {
        var working = session(status: .working, agoSeconds: 600)
        let started = UInt64(now.timeIntervalSince1970) - 90
        working.turns = [AgentTurn(turnCount: 1, status: .running, startedAt: started)]

        let status = SessionListPresentation.rowStatus(
            working, now: UInt64(now.timeIntervalSince1970)
        )
        guard case .working(let elapsed) = status else {
            return XCTFail("a running turn reports its own elapsed time")
        }
        XCTAssertEqual(elapsed, 90)
    }

    func testAWaitingSessionReportsWaitingEvenMidTurn() {
        var waiting = session(status: .waiting)
        waiting.turns = [AgentTurn(turnCount: 1, status: .running, startedAt: 0)]
        XCTAssertEqual(SessionListPresentation.rowStatus(waiting, now: 100), .waiting)
    }

    /// Ticking every row every second on a phone is a battery bug. Only a
    /// running turn needs one-second updates.
    func testRefreshDelayIsOneSecondOnlyWhileATurnRuns() {
        var working = session(status: .working)
        working.turns = [AgentTurn(turnCount: 1, status: .running, startedAt: 0)]
        XCTAssertEqual(
            SessionListPresentation.nextRefreshDelay([working], now: now, calendar: calendar), 1
        )

        let settled = session(agoSeconds: 30)
        let delay = SessionListPresentation.nextRefreshDelay(
            [settled], now: now, calendar: calendar
        )
        XCTAssertEqual(delay, 30, "a reply 30s old next reads differently at one minute")
    }
}
