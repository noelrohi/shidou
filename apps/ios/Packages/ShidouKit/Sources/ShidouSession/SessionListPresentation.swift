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
        // An Archived Task leaves the recency history entirely — it belongs to
        // the Task Shelf, which `groups` builds.
        let started = sessions
            .filter { hasStarted($0) && !$0.isArchived }
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
        /// The Task Shelf: every Archived Task, in one section under the rest.
        case shelf
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
    /// Everything the group holds, including whatever `hasMore` is holding
    /// back. The Task Shelf shows this in its header.
    public var totalCount: Int

    public var id: String { key }

    /// Project and scratch sections are folders — they draw a folder glyph and
    /// an indent guide. Date sections are derived from timestamps and draw
    /// neither.
    public var isFolder: Bool {
        switch kind {
        case .date, .shelf: false
        case .project, .projectless: true
        }
    }

    /// The Task Shelf, which the list draws with its own glyph and keeps
    /// collapsed until asked.
    public var isShelf: Bool { kind == .shelf }
}

extension SessionListPresentation {
    /// Project sections list only the last three days up front.
    public static let projectRecentWindow: TimeInterval = 3 * 24 * 60 * 60
    /// How many older tasks each "Show more" reveals.
    public static let projectRevealBatch = 30
    /// The Task Shelf's section key, stable across a grouping switch the way
    /// every other section key is.
    public static let shelfKey = "shelf"

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

        // An Archived Task leaves the grouped history entirely and gathers on
        // the Task Shelf instead. The mark rides along on the row the list
        // already reads, so this is a field test and nothing more: the phone
        // renders the daemon's decision and never makes one.
        let shelved = items.filter(\.session.isArchived)
        let live = items.filter { !$0.session.isArchived }

        var groups = grouping == .project
            ? projectGroups(
                live, projectsById: projectsById, revealed: revealed, now: now,
                projectlessName: projectlessName)
            : dateGroups(live, ordering: ordering, now: now, calendar: calendar)
        for index in groups.indices {
            groups[index].items = nestChildTasks(groups[index].items)
        }
        if groups.isEmpty {
            // An empty result still needs its first header, or the section
            // actions disappear along with the history.
            groups = grouping == .project
                ? [
                    SessionListGroup(
                        key: "projectless", kind: .projectless, folderName: projectlessName,
                        items: [], hasMore: false, totalCount: 0)
                ]
                : [
                    SessionListGroup(
                        key: "updated:today", kind: .date(.today), folderName: nil, items: [],
                        hasMore: false, totalCount: 0)
                ]
        }
        if let shelf = shelfGroup(shelved, revealed: revealed) { groups.append(shelf) }
        return groups
    }

    /// Places each visible Child Task directly after its parent while keeping
    /// root Tasks in the selected sort order. If the parent is outside this
    /// section, the child remains a root here rather than disappearing.
    private static func nestChildTasks(_ items: [SessionListItem]) -> [SessionListItem] {
        let present = Set(items.map(\.session.id))
        var childrenByParent: [UUID: [SessionListItem]] = [:]
        var roots: [SessionListItem] = []
        for item in items {
            guard let parent = item.session.parentTaskId, present.contains(parent) else {
                roots.append(item)
                continue
            }
            childrenByParent[parent, default: []].append(item)
        }

        var nested: [SessionListItem] = []
        var stack = Array(roots.reversed())
        while let item = stack.popLast() {
            nested.append(item)
            if let children = childrenByParent[item.session.id] {
                stack.append(contentsOf: children.reversed())
            }
        }
        return nested
    }

    /// The Task Shelf: one section under every group, in both grouping modes,
    /// ordered by when each task was shelved rather than by the list's ordering
    /// preference — a shelved task's place is where the user put it.
    ///
    /// There is no recency window here, only paging: a shelved task is old by
    /// definition, so the shelf shows one batch and reveals another with every
    /// "Show more". Nothing archived means no shelf at all.
    private static func shelfGroup(
        _ items: [SessionListItem],
        revealed: [String: Int]
    ) -> SessionListGroup? {
        guard !items.isEmpty else { return nil }
        let ordered = items.sorted {
            ($0.session.archivedAt ?? 0) > ($1.session.archivedAt ?? 0)
        }
        let visible = projectRevealBatch + (revealed[shelfKey] ?? 0)
        return SessionListGroup(
            key: shelfKey, kind: .shelf, folderName: nil,
            items: Array(ordered.prefix(visible)), hasMore: ordered.count > visible,
            totalCount: ordered.count)
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
                items: items, hasMore: false, totalCount: items.count)
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
                    hasMore: false, totalCount: 0))
        }
        if !projectless.isEmpty {
            groups.append(
                SessionListGroup(
                    key: "projectless", kind: .projectless, folderName: projectlessName,
                    items: projectless, hasMore: false, totalCount: 0))
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
            group.totalCount = group.items.count
            group.items = visible
            return group
        }
    }
}
