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
    /// A running turn shows a spinner, not seconds, so it needs no timer at
    /// all; everything else changes at the next minute, hour, day, or local
    /// midnight — which is minutes or hours away, and a phone should be
    /// asleep in between.
    public static func nextRefreshDelay(
        _ sessions: [AgentSession],
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> TimeInterval {
        let nowSeconds = UInt64(now.timeIntervalSince1970)
        var next = secondsUntilLocalMidnight(now: now, calendar: calendar)
        for session in sessions {
            switch rowStatus(session, now: nowSeconds) {
            case .replied(let ago):
                let step = ago < 3_600 ? 60 : ago < 86_400 ? 3_600 : 86_400
                next = min(next, TimeInterval(max(1, step - ago % step)))
            case .working, .waiting, .failed, .none:
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

// MARK: - Sidebar grouping

/// How the sidebar files tasks, ported from the web client's
/// `SidebarGrouping`. Recency is the default because it answers "what was I
/// just doing"; project answers "what is going on in this repo".
public enum SessionListGrouping: String, Sendable, CaseIterable, Codable {
    case updated, project
}

/// Newest-first is the default; the reverse is for reading a long day forward.
public enum SessionListOrdering: String, Sendable, CaseIterable, Codable {
    case newest, oldest
}

/// One collapsible sidebar section. Keys are stable across a grouping switch,
/// so each view keeps its own disclosure state when the user toggles back.
public struct SessionListGroup: Identifiable, Sendable {
    public enum Kind: Hashable, Sendable {
        case date(SessionDateGroup)
        case project(UUID)
        case projectless
    }

    public var key: String
    public var kind: Kind
    /// A folder section's name — the project, or the scratch section's label.
    /// Date sections carry none: their titles are localized recency buckets,
    /// which belong to the view layer that already owns that catalog.
    public var folderName: String?
    public var items: [SessionListItem]
    /// Older tasks this project group is holding back until asked.
    public var hasMore: Bool

    public var id: String { key }

    /// Project and scratch sections are folders — they draw a folder glyph and
    /// an indent guide. Date sections are derived from timestamps and draw
    /// neither.
    public var isFolder: Bool {
        if case .date = kind { return false }
        return true
    }
}

extension SessionListPresentation {
    /// Project sections list only the last three days up front.
    public static let projectRecentWindow: TimeInterval = 3 * 24 * 60 * 60
    /// How many older tasks each "Show more" reveals.
    public static let projectRevealBatch = 30

    /// The sidebar's sections, in display order.
    ///
    /// This is the web sidebar's `sidebarGroups` with the same contracts: only
    /// started tasks, stable keys, an empty first section rather than nothing
    /// so the header actions never vanish, and project sections that hold back
    /// anything older than three days behind a reveal count.
    public static func groups(
        sessions: [AgentSession],
        projects: [Project],
        grouping: SessionListGrouping = .updated,
        ordering: SessionListOrdering = .newest,
        query: String = "",
        revealed: [String: Int] = [:],
        now: Date = Date(),
        calendar: Calendar = .current,
        unknownProjectName: String = "Unknown project",
        projectlessName: String = "No project"
    ) -> [SessionListGroup] {
        let projectsById = Dictionary(
            projects.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let items = sessions
            .filter(hasStarted)
            .map { session -> SessionListItem in
                let project = projectsById[session.projectId]
                return SessionListItem(
                    session: session,
                    projectName: project.map { $0.isProjectless ? projectlessName : $0.name }
                        ?? unknownProjectName,
                    projectPath: project?.path,
                    branch: {
                        if case .worktree(_, let branch) = session.workspace { return branch }
                        return nil
                    }(),
                    timestamp: timestamp(session)
                )
            }
            .filter { matches($0, query: query) }
            .sorted {
                ordering == .oldest ? $0.timestamp < $1.timestamp : $0.timestamp > $1.timestamp
            }

        let groups = grouping == .project
            ? projectGroups(
                items, projectsById: projectsById, revealed: revealed, now: now,
                projectlessName: projectlessName)
            : dateGroups(items, ordering: ordering, now: now, calendar: calendar)
        if !groups.isEmpty { return groups }
        // An empty result still needs its first header, or the section actions
        // disappear along with the history.
        if grouping == .project {
            return [
                SessionListGroup(
                    key: "projectless", kind: .projectless, folderName: projectlessName,
                    items: [], hasMore: false)
            ]
        }
        return [
            SessionListGroup(
                key: "updated:today", kind: .date(.today), folderName: nil, items: [],
                hasMore: false)
        ]
    }

    /// Whether a row survives the search field. Title, project, and branch are
    /// what the row itself shows, so they are what it can be found by.
    public static func matches(_ item: SessionListItem, query: String) -> Bool {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return true }
        let haystack = [displayTitle(item.session), item.projectName, item.branch ?? ""]
        return haystack.contains {
            $0.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }
    }

    private static func dateGroups(
        _ items: [SessionListItem],
        ordering: SessionListOrdering,
        now: Date,
        calendar: Calendar
    ) -> [SessionListGroup] {
        var grouped: [SessionDateGroup: [SessionListItem]] = [:]
        for item in items {
            grouped[dateGroup(item.timestamp, now: now, calendar: calendar), default: []]
                .append(item)
        }
        let order = ordering == .oldest
            ? SessionDateGroup.allCases.reversed().map { $0 }
            : SessionDateGroup.allCases
        return order.compactMap { group in
            guard let items = grouped[group], !items.isEmpty else { return nil }
            return SessionListGroup(
                key: "updated:\(group.rawValue)", kind: .date(group), folderName: nil,
                items: items, hasMore: false)
        }
    }

    private static func projectGroups(
        _ items: [SessionListItem],
        projectsById: [UUID: Project],
        revealed: [String: Int],
        now: Date,
        projectlessName: String
    ) -> [SessionListGroup] {
        var groups: [SessionListGroup] = []
        var indexByProject: [UUID: Int] = [:]
        var projectless: [SessionListItem] = []
        for item in items {
            let project = projectsById[item.session.projectId]
            if let project, project.isProjectless {
                projectless.append(item)
                continue
            }
            let id = item.session.projectId
            if let index = indexByProject[id] {
                groups[index].items.append(item)
                continue
            }
            indexByProject[id] = groups.count
            groups.append(
                SessionListGroup(
                    key: "project:\(id.uuidString)", kind: .project(id),
                    folderName: project?.name ?? item.projectName, items: [item],
                    hasMore: false))
        }
        if !projectless.isEmpty {
            groups.append(
                SessionListGroup(
                    key: "projectless", kind: .projectless, folderName: projectlessName,
                    items: projectless, hasMore: false))
        }
        let cutoff = UInt64(max(0, now.timeIntervalSince1970 - projectRecentWindow))
        return groups.map { group in
            var group = group
            let revealedOlder = revealed[group.key] ?? 0
            var visible: [SessionListItem] = []
            var olderSeen = 0
            for item in group.items {
                if item.timestamp >= cutoff || olderSeen < revealedOlder { visible.append(item) }
                if item.timestamp < cutoff { olderSeen += 1 }
            }
            group.hasMore = olderSeen > revealedOlder
            group.items = visible
            return group
        }
    }
}
