import Foundation
import ShidouProtocol

// Activity row copy, ported from the web client's
// `lib/transcript-presentation.ts`. The daemon sends a generic `title` plus
// structured fields, and the phrasing is the client's job — so it has to be
// the same phrasing on every client.
//
// Strings here are `String(localized:)`-free on purpose: the app target owns
// the string catalog, and these values interpolate file names and commands
// that a catalog entry would have to carry anyway. `ActivityLabel` returns the
// pieces; the view assembles and localizes them.

/// What a row says, split so the view can localize the verb and lay out the
/// subject in its own style.
public struct ActivityLabel: Hashable, Sendable {
    public enum Verb: String, Hashable, Sendable {
        case think, run, edit, read, search, list, plan, tool, ask
    }

    /// The action, before the subject: `Read`, `Editing`, `Failed to edit`.
    public var action: Action
    /// The file, command, or query the action applies to. May be empty.
    public var subject: String
    /// The short verb for a compact chip.
    public var verb: Verb

    public enum Action: Hashable, Sendable {
        case thinking
        case thought(seconds: Int)
        case running(ActivityKind)
        case completed(ActivityKind)
        case failed(ActivityKind)
        /// The daemon gave a specific title, so use it verbatim.
        case verbatim(String)
    }
}

public enum ActivityPresentation {
    /// Titles the daemon emits when it has nothing specific to say. The web
    /// client replaces these with its own phrasing and keeps anything else.
    private static let genericTitles: Set<String> = [
        "Edit", "Read", "List", "Search", "Command", "Plan", "Tool", "Reasoning", "Thinking",
        "Bash", "Write", "Task",
    ]

    public static func isGenericTitle(_ activity: ActivityItem) -> Bool {
        genericTitles.contains(activity.title.trimmingCharacters(in: .whitespaces))
    }

    public static func label(for activity: ActivityItem) -> ActivityLabel {
        let target = activity.displayTarget?.trimmingCharacters(in: .whitespaces).nonEmpty

        if activity.kind == .reasoning {
            guard let reasoning = activity.reasoning else {
                return ActivityLabel(
                    action: .verbatim(activity.title), subject: "", verb: .think
                )
            }
            guard activity.complete else {
                return ActivityLabel(action: .thinking, subject: "", verb: .think)
            }
            let millis = reasoning.finishedAtMs >= reasoning.startedAtMs
                ? reasoning.finishedAtMs - reasoning.startedAtMs : 0
            return ActivityLabel(
                action: .thought(seconds: max(1, Int((millis + 999) / 1_000))),
                subject: "",
                verb: .think
            )
        }

        let subject: String
        switch activity.kind {
        case .fileChange:
            if activity.fileChanges.count == 1 {
                subject = pathName(activity.fileChanges[0].path)
            } else if activity.fileChanges.count > 1 {
                subject = "\(activity.fileChanges.count) files"
            } else {
                subject = ""
            }
        case .fileRead, .fileList:
            subject = target.map(pathName) ?? ""
        case .command:
            subject = activity.displayDescription?.trimmingCharacters(in: .whitespaces).nonEmpty
                ?? target ?? ""
        case .fileSearch, .search:
            subject = target ?? ""
        default:
            subject = target ?? ""
        }

        // A daemon that named the activity itself outranks our phrasing, but
        // only when we have nothing concrete to put in the sentence.
        if subject.isEmpty && !isGenericTitle(activity) {
            return ActivityLabel(
                action: .verbatim(activity.title), subject: "", verb: verb(for: activity)
            )
        }
        let action: ActivityLabel.Action =
            !activity.complete
            ? .running(activity.kind)
            : activity.failed ? .failed(activity.kind) : .completed(activity.kind)
        return ActivityLabel(action: action, subject: subject, verb: verb(for: activity))
    }

    public static func verb(for activity: ActivityItem) -> ActivityLabel.Verb {
        switch activity.kind {
        case .reasoning: return .think
        case .command: return .run
        case .fileChange: return .edit
        case .fileRead: return .read
        case .fileSearch, .search: return .search
        case .fileList: return .list
        case .plan: return .plan
        case .tool, .unknown: return .tool
        }
    }

    /// Additions and deletions, only once an edit has landed successfully.
    public static func fileChangeStats(_ activity: ActivityItem) -> (additions: UInt64, deletions: UInt64)? {
        guard activity.kind == .fileChange, activity.complete, !activity.failed else { return nil }
        let changes = activity.fileChanges
        guard !changes.isEmpty,
            !changes.contains(where: { $0.additions == nil || $0.deletions == nil })
        else { return nil }
        return (
            changes.reduce(0) { $0 + ($1.additions ?? 0) },
            changes.reduce(0) { $0 + ($1.deletions ?? 0) }
        )
    }

    /// The one-line preview under a collapsed activity.
    public static func preview(_ activity: ActivityItem) -> String {
        let detail = activity.detail?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if detail.lowercased() == "failed",
            let line = activity.output?
                .split(separator: "\n")
                .first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty })
        {
            return line.trimmingCharacters(in: .whitespaces)
        }
        if detail.isEmpty || detail.lowercased() == "failed", !activity.imageUrls.isEmpty {
            return "Image output"
        }
        return detail
    }

    /// The expandable body of an activity: command, arguments, output.
    public struct DisclosureSection: Hashable, Sendable {
        public enum Kind: Hashable, Sendable { case command, arguments, output, detail, diff }
        public var kind: Kind
        public var content: String
        public var isDiffMissing: Bool = false
    }

    public static func disclosureSections(_ activity: ActivityItem) -> [DisclosureSection] {
        var sections: [DisclosureSection] = []
        if activity.kind == .fileChange, activity.complete, !activity.failed {
            for change in activity.fileChanges {
                guard !change.path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                if let diff = change.diff,
                    !diff.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                {
                    sections.append(DisclosureSection(kind: .diff, content: "\(change.path)\n\(diff)"))
                } else {
                    sections.append(DisclosureSection(kind: .diff, content: change.path, isDiffMissing: true))
                }
            }
        }
        let output = activity.output?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
        if activity.kind == .command {
            if let command = activity.arguments?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
                ?? activity.displayTarget?.trimmingCharacters(in: .whitespaces).nonEmpty
            {
                sections.append(DisclosureSection(kind: .command, content: command))
            }
            if let output {
                sections.append(DisclosureSection(kind: .output, content: output))
            } else if !activity.imageUrls.isEmpty {
                sections.append(DisclosureSection(kind: .output, content: ""))
            }
            return sections
        }
        if let arguments = activity.arguments?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty {
            sections.append(DisclosureSection(kind: .arguments, content: arguments))
        }
        if let output {
            sections.append(DisclosureSection(kind: .output, content: output))
        } else if !activity.imageUrls.isEmpty {
            sections.append(DisclosureSection(kind: .output, content: ""))
        }
        if sections.isEmpty,
            let detail = activity.detail?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
        {
            sections.append(DisclosureSection(kind: .detail, content: detail))
        }
        return sections
    }

    /// `Ran 2 commands · 1 file` for a collapsed group.
    public static func summaryCounts(_ activities: [ActivityItem]) -> [(kind: ActivityKind, count: Int)] {
        var order: [ActivityKind] = []
        var counts: [ActivityKind: Int] = [:]
        for activity in activities {
            if counts[activity.kind] == nil { order.append(activity.kind) }
            counts[activity.kind, default: 0] += 1
        }
        return order.map { ($0, counts[$0] ?? 0) }
    }

    public static func pathName(_ path: String) -> String {
        let parts = path.split(whereSeparator: { $0 == "/" || $0 == "\\" })
        return parts.last.map(String.init) ?? path
    }
}

extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
