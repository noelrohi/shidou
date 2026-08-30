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

    /// Ticking every row every second on a phone is a battery bug. A running
    /// turn shows a spinner rather than seconds, so it asks for no timer.
    func testRefreshDelayDoesNotTickForARunningTurn() {
        var working = session(status: .working)
        working.turns = [AgentTurn(turnCount: 1, status: .running, startedAt: 0)]
        XCTAssertGreaterThan(
            SessionListPresentation.nextRefreshDelay([working], now: now, calendar: calendar), 1
        )

        let settled = session(agoSeconds: 30)
        let delay = SessionListPresentation.nextRefreshDelay(
            [settled], now: now, calendar: calendar
        )
        XCTAssertEqual(delay, 30, "a reply 30s old next reads differently at one minute")
    }

    // MARK: - Sidebar grouping

    private func session(
        in projectId: UUID,
        title: String,
        agoSeconds: TimeInterval = 0
    ) -> AgentSession {
        let stamp = UInt64(now.timeIntervalSince1970 - agoSeconds)
        return AgentSession(
            title: title,
            projectId: projectId,
            provider: .claude,
            status: .idle,
            createdAt: stamp,
            updatedAt: stamp,
            lastReplyAt: stamp,
            messages: [Message(role: .user, content: "hi", createdAt: stamp)]
        )
    }

    func testProjectGroupingFilesTasksUnderTheirProject() {
        let other = Project(name: "notes", path: "/src/notes", createdAt: 0)
        let groups = SessionListPresentation.groups(
            sessions: [
                session(in: projectId, title: "a"),
                session(in: other.id, title: "b", agoSeconds: 60),
            ],
            projects: [project, other],
            grouping: .project,
            now: now,
            calendar: calendar
        )
        XCTAssertEqual(groups.map(\.folderName), ["shidou", "notes"])
        XCTAssertEqual(groups[0].items.map(\.session.title), ["a"])
        XCTAssertTrue(groups.allSatisfy(\.isFolder))
    }

    /// The scratch section is bookkeeping for whatever has no project, so it
    /// sorts last however recent its tasks are.
    func testTheScratchProjectSortsLast() {
        let scratch = Project(name: Project.projectlessName, path: "/tmp", createdAt: 0)
        let groups = SessionListPresentation.groups(
            sessions: [
                session(in: scratch.id, title: "scratch"),
                session(in: projectId, title: "real", agoSeconds: 600),
            ],
            projects: [project, scratch],
            grouping: .project,
            now: now,
            calendar: calendar,
            projectlessName: "No project"
        )
        XCTAssertEqual(groups.map(\.folderName), ["shidou", "No project"])
    }

    func testOldestFirstReversesSectionsAndRows() {
        let groups = SessionListPresentation.groups(
            sessions: [
                session(title: "now", agoSeconds: 60),
                session(title: "earlier", agoSeconds: 3_600),
                session(title: "yesterday", agoSeconds: 86_400),
            ],
            projects: [project],
            ordering: .oldest,
            now: now,
            calendar: calendar
        )
        XCTAssertEqual(groups.map(\.key), ["updated:yesterday", "updated:today"])
        XCTAssertEqual(groups[1].items.map(\.session.title), ["earlier", "now"])
    }

    func testSearchMatchesTitleProjectAndBranch() {
        var worktree = session(title: "unrelated")
        worktree.workspace = .worktree(path: "/src/wt", branch: "feature/login")
        let sessions = [session(title: "Fix the parser"), worktree]
        let hits = { (query: String) in
            SessionListPresentation.groups(
                sessions: sessions, projects: [self.project], query: query,
                now: self.now, calendar: self.calendar
            ).flatMap(\.items).map(\.session.title)
        }
        XCTAssertEqual(hits("parser"), ["Fix the parser"])
        XCTAssertEqual(hits("LOGIN"), ["unrelated"], "search ignores case")
        XCTAssertEqual(hits("shidou").count, 2, "the project name matches every row in it")
        XCTAssertEqual(hits("   ").count, 2, "a blank query is no query")
    }

    /// A project section that listed every task it ever had would bury the
    /// three days that are actually in play.
    func testProjectSectionsHoldBackOlderTasksUntilAsked() {
        let sessions = [session(title: "recent")]
            + (0..<3).map { session(title: "old\($0)", agoSeconds: 10 * 86_400 + Double($0)) }
        let held = SessionListPresentation.groups(
            sessions: sessions, projects: [project], grouping: .project,
            now: now, calendar: calendar
        )
        XCTAssertEqual(held[0].items.map(\.session.title), ["recent"])
        XCTAssertTrue(held[0].hasMore)

        let revealed = SessionListPresentation.groups(
            sessions: sessions, projects: [project], grouping: .project,
            revealed: [held[0].key: SessionListPresentation.projectRevealBatch],
            now: now, calendar: calendar
        )
        XCTAssertEqual(revealed[0].items.count, 4)
        XCTAssertFalse(revealed[0].hasMore)
    }

    /// The first header carries the list's options menu, so it has to survive
    /// a search that matches nothing.
    func testAnEmptyResultStillYieldsOneHeader() {
        let groups = SessionListPresentation.groups(
            sessions: [session()], projects: [project], query: "no such task",
            now: now, calendar: calendar
        )
        XCTAssertEqual(groups.count, 1)
        XCTAssertTrue(groups[0].items.isEmpty)
        XCTAssertEqual(groups[0].kind, .date(.today))
    }
}
