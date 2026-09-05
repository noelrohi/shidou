import Foundation
import ShidouProtocol

/// Provider-recorded edit totals, not a net Git diff. Nil counts remain unknown.
public struct RecordedEdits: Sendable {
    public struct File: Sendable {
        public var path: String
        public var additions: UInt64?
        public var deletions: UInt64?
    }

    public var files: [File] = []
    public var additions: UInt64? = 0
    public var deletions: UInt64? = 0
    /// Transcript order, matching the original provider edit activities.
    public var activityIds: [UUID] = []
    public var firstRowKey: String?

    public static func summaries(in session: AgentSession) -> [UUID: RecordedEdits] {
        var summaries: [UUID: RecordedEdits] = [:]
        var indices: [UUID: [String: Int]] = [:]
        for (blockIndex, block) in session.transcriptBlocks.enumerated() {
            guard let turnId = block.turnId else { continue }
            for activity in block.activities where activity.kind == .fileChange
                && activity.complete && !activity.failed && !activity.fileChanges.isEmpty
            {
                var summary = summaries.removeValue(forKey: turnId) ?? RecordedEdits()
                var hasEdits = false
                for change in activity.fileChanges {
                    guard !change.path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                    hasEdits = true
                    summary.additions = sum(summary.additions, change.additions)
                    summary.deletions = sum(summary.deletions, change.deletions)
                    if let index = indices[turnId]?[change.path] {
                        summary.files[index].additions = sum(summary.files[index].additions, change.additions)
                        summary.files[index].deletions = sum(summary.files[index].deletions, change.deletions)
                    } else {
                        indices[turnId, default: [:]][change.path] = summary.files.count
                        summary.files.append(File(
                            path: change.path, additions: change.additions, deletions: change.deletions
                        ))
                    }
                }
                if hasEdits {
                    summary.activityIds.append(activity.id)
                    if summary.firstRowKey == nil { summary.firstRowKey = "block-\(blockIndex)" }
                }
                if !summary.files.isEmpty { summaries[turnId] = summary }
            }
        }
        return summaries
    }

    private static func sum(_ lhs: UInt64?, _ rhs: UInt64?) -> UInt64? {
        guard let lhs, let rhs else { return nil }
        let result = lhs.addingReportingOverflow(rhs)
        return result.overflow ? nil : result.partialValue
    }
}
