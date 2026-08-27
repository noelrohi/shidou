import Foundation
import ShidouProtocol

/// Find-in-transcript, ported from the web client's `lib/transcript-search.ts`.
///
/// Matches come from the projection's own text rather than from mounted rows,
/// so the count and the next/previous navigation cover the whole transcript
/// even though a `LazyVStack` has only a window of it built.
public struct TranscriptMatch: Hashable, Sendable {
    /// Index into the rows the transcript is displaying, for scrolling.
    public var rowIndex: Int
    /// Row identity, for highlighting whichever rows happen to be mounted.
    public var rowKey: String
    /// Zero-based occurrence of the query within this row's text.
    public var ordinal: Int
}

public enum TranscriptFind {
    /// A transcript long enough to reach this has already stopped being
    /// navigable; counting past it costs time and buys nothing.
    public static let matchLimit = 20_000

    /// The searchable text of one row, in the order it reads on screen.
    public static func searchableText(_ row: TranscriptRow) -> String {
        switch row {
        case .message(_, let message):
            return message.message.visibleContent
        case .activities(_, let block, _):
            return block.activities.map(activityText).joined(separator: "\n")
        case .changed(_, _, let checkpoint):
            return checkpoint.files.map(\.path).joined(separator: "\n")
        case .fold, .working:
            return ""
        }
    }

    private static func activityText(_ activity: ActivityItem) -> String {
        var parts = [activity.title]
        if let detail = activity.detail { parts.append(detail) }
        if let target = activity.displayTarget { parts.append(target) }
        if let description = activity.displayDescription { parts.append(description) }
        if let arguments = activity.arguments { parts.append(arguments) }
        if let output = activity.output { parts.append(output) }
        if let reasoning = activity.reasoning { parts.append(reasoning.content) }
        parts.append(contentsOf: activity.fileChanges.map(\.path))
        return parts.joined(separator: "\n")
    }

    public struct Result: Sendable {
        public var matches: [TranscriptMatch]
        /// The search stopped at `matchLimit`; the count shown is a floor.
        public var limited: Bool

        public init(matches: [TranscriptMatch] = [], limited: Bool = false) {
            self.matches = matches
            self.limited = limited
        }
    }

    public static func matches(in rows: [TranscriptRow], query: String, limit: Int = matchLimit) -> Result {
        let needle = query.lowercased()
        guard !needle.isEmpty else { return Result(matches: [], limited: false) }
        var matches: [TranscriptMatch] = []
        for (rowIndex, row) in rows.enumerated() {
            let haystack = searchableText(row).lowercased()
            guard !haystack.isEmpty else { continue }
            var searchStart = haystack.startIndex
            var ordinal = 0
            while let found = haystack.range(of: needle, range: searchStart..<haystack.endIndex) {
                if matches.count >= limit { return Result(matches: matches, limited: true) }
                matches.append(TranscriptMatch(rowIndex: rowIndex, rowKey: row.id, ordinal: ordinal))
                ordinal += 1
                searchStart = found.upperBound
            }
        }
        return Result(matches: matches, limited: false)
    }

    /// Wraps at both ends, so `next` from the last match returns to the first.
    public static func step(current: Int?, count: Int, backward: Bool) -> Int? {
        guard count > 0 else { return nil }
        guard let current else { return backward ? count - 1 : 0 }
        return backward ? (current - 1 + count) % count : (current + 1) % count
    }

    /// Keeps the current match pointing at the same place when the list is
    /// rebuilt — a streaming append renumbers everything after the tail.
    public static func reconcile(previous: TranscriptMatch?, matches: [TranscriptMatch]) -> Int? {
        guard !matches.isEmpty else { return nil }
        guard let previous else { return nil }
        if let exact = matches.firstIndex(where: {
            $0.rowKey == previous.rowKey && $0.ordinal == previous.ordinal
        }) {
            return exact
        }
        if let sameRow = matches.firstIndex(where: { $0.rowKey == previous.rowKey }) {
            return sameRow
        }
        let after = matches.firstIndex { $0.rowIndex >= previous.rowIndex } ?? matches.count - 1
        return min(matches.count - 1, max(0, after))
    }
}
