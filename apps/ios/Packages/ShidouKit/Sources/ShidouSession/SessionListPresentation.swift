import Foundation
import ShidouProtocol

// Session-list grouping and labels, ported from the web client's
// `lib/sidebar-presentation.ts`. The phone shows the same information the web
// sidebar carries, at mobile density: one section per recency bucket, and a
// row that says what the task is, where it lives, and what it is doing.

public enum SessionDateGroup: String, Sendable, CaseIterable {
    case today, yesterday, week, month, year, more
}

public struct SessionListItem: Identifiable, Sendable {
    public var session: AgentSession
    public var projectName: String
    public var projectPath: String?
    /// The worktree branch, when the task runs in one.
    public var branch: String?
    /// Last reply, or creation time for a task that never replied.
    public var timestamp: UInt64

    public var id: UUID { session.id }

    /// Blocked on the user: a pending permission or an unanswered question.
    /// The list marks these because they are the only rows where nothing
    /// happens until the user comes back.
    public var isWaiting: Bool { session.status == .waiting }

    public var isBusy: Bool { session.status.isBusy }
}

public struct SessionListSection: Identifiable, Sendable {
    public var group: SessionDateGroup
    public var items: [SessionListItem]

    public var id: String { group.rawValue }
}

public enum SessionListPresentation {
    /// A task the user has actually started. Drafts that never got a prompt
    /// are the composer's business, not the list's.
    public static func hasStarted(_ session: AgentSession) -> Bool {
        session.hasStarted
    }

    public static func timestamp(_ session: AgentSession) -> UInt64 {
        session.lastReplyAt ?? session.createdAt
    }

    /// Group started sessions by recency, newest first, dropping empty groups.
    public static func sections(
        sessions: [AgentSession],
        projects: [Project],
        now: Date = Date(),
        calendar: Calendar = .current,
        unknownProjectName: String = "Unknown project"
    ) -> [SessionListSection] {
        let projectsById = Dictionary(projects.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let started = sessions
            .filter(hasStarted)
            .sorted { timestamp($0) > timestamp($1) }

        var grouped: [SessionDateGroup: [SessionListItem]] = [:]
        for session in started {
            let project = projectsById[session.projectId]
            let item = SessionListItem(
                session: session,
                projectName: project?.name ?? unknownProjectName,
                projectPath: project?.path,
                branch: {
                    if case .worktree(_, let branch) = session.workspace { return branch }
                    return nil
                }(),
                timestamp: timestamp(session)
            )
            grouped[dateGroup(item.timestamp, now: now, calendar: calendar), default: []].append(item)
        }
        return SessionDateGroup.allCases.compactMap { group in
            guard let items = grouped[group], !items.isEmpty else { return nil }
            return SessionListSection(group: group, items: items)
        }
    }

    public static func dateGroup(
        _ timestamp: UInt64,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> SessionDateGroup {
        let date = Date(timeIntervalSince1970: TimeInterval(timestamp))
        let today = calendar.startOfDay(for: now)
        let day = calendar.startOfDay(for: date)
        if day >= today { return .today }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: today), day == yesterday {
            return .yesterday
        }
        if let weekStart = calendar.dateInterval(of: .weekOfYear, for: now)?.start, day >= weekStart {
            return .week
        }
        let dayParts = calendar.dateComponents([.year, .month], from: day)
        let todayParts = calendar.dateComponents([.year, .month], from: today)
        if dayParts.year == todayParts.year, dayParts.month == todayParts.month { return .month }
        if dayParts.year == todayParts.year { return .year }
        return .more
    }

    // MARK: - Row status

    /// What a row's status line says: either how long the current turn has
    /// been running, or how long ago the last reply landed.
    public enum RowStatus: Hashable, Sendable {
        case working(elapsedSeconds: Int)
        case waiting
        case failed
        case replied(agoSeconds: Int)
        case none
    }

    public static func rowStatus(_ session: AgentSession, now: UInt64 = UInt64(Date().timeIntervalSince1970)) -> RowStatus {
        let turn = session.turns.last
        if session.status == .waiting { return .waiting }
        if session.status == .failed { return .failed }
        if session.status.isBusy, turn?.status == .running, let started = turn?.startedAt {
            return .working(elapsedSeconds: Int(now > started ? now - started : 0))
        }
        guard let lastReply = session.lastReplyAt else { return .none }
        return .replied(agoSeconds: Int(now > lastReply ? now - lastReply : 0))
    }

    /// Seconds until a status line would read differently, so the list can
    /// schedule one timer instead of ticking every row every second.
    ///
    /// A running turn shows seconds and needs one-second updates; everything
    /// else changes at the next minute, hour, day, or local midnight — which
    /// is minutes or hours away, and a phone should be asleep in between.
    public static func nextRefreshDelay(
        _ sessions: [AgentSession],
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> TimeInterval {
        let nowSeconds = UInt64(now.timeIntervalSince1970)
        var next = secondsUntilLocalMidnight(now: now, calendar: calendar)
        for session in sessions {
            switch rowStatus(session, now: nowSeconds) {
            case .working:
                return 1
            case .replied(let ago):
                let step = ago < 3_600 ? 60 : ago < 86_400 ? 3_600 : 86_400
                next = min(next, TimeInterval(max(1, step - ago % step)))
            case .waiting, .failed, .none:
                continue
            }
        }
        return next
    }

    private static func secondsUntilLocalMidnight(now: Date, calendar: Calendar) -> TimeInterval {
        guard let tomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now))
        else { return 3_600 }
        return max(1, tomorrow.timeIntervalSince(now))
    }
}
