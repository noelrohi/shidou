import ShidouProtocol
import ShidouSession
import SwiftUI

// One view per transcript row type. Every row the web transcript renders has a
// counterpart here, adapted to touch: nothing depends on hover, and anything
// that discloses is a control a VoiceOver user can reach.

struct UserMessageRow: View {
    let message: Message

    var body: some View {
        HStack(alignment: .top) {
            Spacer(minLength: 44)
            Text(message.visibleContent)
                .textSelection(.enabled)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(
                    Color.accentColor.opacity(0.15), in: RoundedRectangle(cornerRadius: 18)
                )
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("You said: \(message.visibleContent)")
    }
}

struct AssistantMessageRow: View {
    let row: MessageRow
    let markdown: MarkdownStore
    let highlights: HighlightStore
    let workspaceCwd: String?
    let onOpenFile: (TranscriptLinkRoute) -> Void

    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            MarkdownBlocksView(
                blocks: markdown.blocks(
                    for: row.message.id,
                    content: row.message.content,
                    streaming: row.message.streaming
                ),
                highlights: highlights,
                onOpenLink: open
            )
            if let checkpoint = row.checkpoint {
                CheckpointSummary(checkpoint: checkpoint)
            }
            if let footer = row.footer {
                AssistantFooter(footer: footer)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func open(_ target: String) {
        let route = TranscriptLinks.route(target: target, workspace: workspaceCwd)
        switch route {
        case .external:
            if let url = URL(string: target) { openURL(url) }
        case .projectFile, .remoteFile:
            onOpenFile(route)
        }
    }
}

private struct AssistantFooter: View {
    let footer: AssistantResponseFooter

    @State private var copied = false

    var body: some View {
        HStack(spacing: 12) {
            Text(footer.timestamp.messageTimeLabel)
                .font(.caption2)
                .foregroundStyle(.tertiary)
            Button {
                UIPasteboard.general.string = footer.content
                copied = true
            } label: {
                Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                    .font(.caption2)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .frame(minHeight: 32)
            .contentShape(Rectangle())
            .accessibilityLabel(copied ? "Response copied" : "Copy response")
            Spacer(minLength: 0)
        }
    }
}

/// A settled turn's work, collapsed behind one row. Tapping expands it, which
/// is the touch equivalent of the desktop's fold.
struct TurnFoldRow: View {
    let turn: AgentTurn
    let expanded: Bool
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 10) {
                line
                HStack(spacing: 4) {
                    Text(label)
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.caption2)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                // The rules give way, not the label: this is a divider, and a
                // divider whose caption wraps to three lines has stopped
                // dividing anything.
                .fixedSize()
                line
            }
            .frame(minHeight: 34)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // VoiceOver gets the spelled-out duration. "1m 33s" is a compression
        // for a row that has one line to spend; speech has no such limit, and
        // read aloud the abbreviations are worse than the words.
        .accessibilityLabel(spokenLabel)
        .accessibilityHint(expanded ? "Hides this turn's work" : "Shows this turn's work")
        .accessibilityAddTraits(expanded ? [.isButton, .isSelected] : .isButton)
    }

    private var line: some View {
        Rectangle().fill(.quaternary).frame(height: 1)
    }

    private var label: String { label(seconds.durationShortLabel) }

    private var spokenLabel: String { label(seconds.durationLabel) }

    private var seconds: Int {
        let end = turn.completedAt ?? UInt64(Date().timeIntervalSince1970)
        return Int(max(1, end > turn.startedAt ? end - turn.startedAt : 1))
    }

    private func label(_ duration: String) -> String {
        if turn.status == .interrupted {
            return String(localized: "You stopped after \(duration)")
        }
        return String(localized: "Worked for \(duration)")
    }
}

/// A group of tool activity. Collapsed it says what happened; expanded, each
/// activity discloses its command, arguments and output.
struct ActivityGroupRow: View {
    let block: TranscriptBlock
    let isLive: Bool

    @State private var expandedActivities: Set<UUID> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(block.activities) { activity in
                ActivityRow(
                    activity: activity,
                    expanded: expandedActivities.contains(activity.id),
                    toggle: {
                        if expandedActivities.contains(activity.id) {
                            expandedActivities.remove(activity.id)
                        } else {
                            expandedActivities.insert(activity.id)
                        }
                    }
                )
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
        .overlay(alignment: .leading) {
            if isLive {
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.accentColor)
                    .frame(width: 3)
                    .accessibilityHidden(true)
            }
        }
    }
}

private struct ActivityRow: View {
    let activity: ActivityItem
    let expanded: Bool
    let toggle: () -> Void

    private var sections: [ActivityPresentation.DisclosureSection] {
        ActivityPresentation.disclosureSections(activity)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button(action: toggle) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    statusGlyph
                    VStack(alignment: .leading, spacing: 2) {
                        // One line, always. A row is an index of the turn's
                        // work, and a wrapped shell command turns six of them
                        // into a screenful; the whole command is one tap away
                        // in the disclosure below.
                        Text(title)
                            .font(.callout)
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        if let stats = ActivityPresentation.fileChangeStats(activity) {
                            Text(verbatim: "+\(stats.additions) −\(stats.deletions)")
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.secondary)
                        } else if !preview.isEmpty {
                            Text(preview)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(expanded ? nil : 1)
                        }
                    }
                    Spacer(minLength: 4)
                    if !sections.isEmpty {
                        Image(systemName: expanded ? "chevron.down" : "chevron.right")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
                .frame(minHeight: 32)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(sections.isEmpty)
            .accessibilityLabel(accessibilityLabel)
            .accessibilityHint(sections.isEmpty ? "" : (expanded ? "Hides the details" : "Shows the details"))

            if expanded {
                ForEach(Array(sections.enumerated()), id: \.offset) { _, section in
                    ActivityDisclosure(section: section)
                }
            }
            if activity.kind == .reasoning, let reasoning = activity.reasoning, expanded || !activity.complete {
                Text(reasoning.content)
                    .font(.callout.italic())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
    }

    /// Status is a glyph as well as a colour, so it survives both a
    /// colour-blind reader and a screenshot in grayscale.
    private var statusGlyph: some View {
        Image(systemName: activity.failed
            ? "exclamationmark.triangle.fill"
            : activity.complete ? "checkmark.circle" : "circle.dotted")
            .font(.caption)
            .foregroundStyle(activity.failed ? Color.orange : activity.complete ? Color.green : .secondary)
            .accessibilityHidden(true)
    }

    private var preview: String { ActivityPresentation.preview(activity) }

    private var title: String {
        let label = ActivityPresentation.label(for: activity)
        return ActivityCopy.sentence(label).oneLine
    }

    private var accessibilityLabel: String {
        let status = activity.failed
            ? String(localized: "Failed")
            : activity.complete ? String(localized: "Done") : String(localized: "Running")
        return "\(title). \(status)"
    }
}

private struct ActivityDisclosure: View {
    let section: ActivityPresentation.DisclosureSection

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let label {
                Text(label)
                    .font(.caption2.smallCaps())
                    .foregroundStyle(.tertiary)
            }
            if section.content.isEmpty {
                Text("Image output")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    Text(section.content)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                }
                .frame(maxHeight: 260)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
    }

    private var label: String? {
        switch section.kind {
        case .command: return String(localized: "Command")
        case .arguments: return String(localized: "Arguments")
        case .output: return String(localized: "Output")
        case .detail: return nil
        }
    }
}

/// A turn's checkpoint, display-only. Restoring one is deferred past v1, so
/// the row states what changed and offers nothing it cannot do.
struct CheckpointSummary: View {
    let checkpoint: Checkpoint

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "square.and.pencil")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Text("Changed \(checkpoint.files.count) file")
                    .font(.caption.bold())
                Text(verbatim: "+\(checkpoint.additions) −\(checkpoint.deletions)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            ForEach(checkpoint.files, id: \.path) { file in
                HStack(spacing: 6) {
                    Text(file.path)
                        .font(.caption2.monospaced())
                        .lineLimit(1)
                        .truncationMode(.head)
                    Spacer(minLength: 4)
                    Text(verbatim: "+\(file.additions) −\(file.deletions)")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .combine)
    }
}

/// The tail of a live turn. A turn blocked on the user is not working, so it
/// does not claim to be: the prompt that unblocks it arrives in slice ②, and
/// until then the honest sentence is the only thing standing in for it.
struct WorkingRow: View {
    let startedAt: UInt64
    let now: UInt64
    let isWaiting: Bool

    var body: some View {
        HStack(spacing: 8) {
            if isWaiting {
                Image(systemName: "hand.raised.fill")
                    .font(.footnote)
                    .foregroundStyle(.orange)
                    .accessibilityHidden(true)
            } else {
                ProgressView().controlSize(.small)
            }
            Text(label)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .monospacedDigit()
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
    }

    private var label: String {
        isWaiting
            ? String(localized: "Waiting for you")
            : String(localized: "Working for \(elapsed.durationShortLabel)")
    }

    private var accessibilityLabel: String {
        isWaiting
            ? String(localized: "Waiting for you")
            : String(localized: "Working for \(elapsed.durationLabel)")
    }

    private var elapsed: Int { Int(now > startedAt ? now - startedAt : 0) }
}

// MARK: - Copy

enum ActivityCopy {
    /// Turns the structured label into the sentence the row shows. Kept in one
    /// place so every phrasing goes through the string catalog once.
    static func sentence(_ label: ActivityLabel) -> String {
        let subject = label.subject
        switch label.action {
        case .verbatim(let title):
            return title
        case .thinking:
            return String(localized: "Thinking")
        case .thought(let seconds):
            return String(localized: "Thought for \(seconds.durationLabel)")
        case .running(let kind):
            return running(kind, subject)
        case .completed(let kind):
            return completed(kind, subject)
        case .failed(let kind):
            return failed(kind, subject)
        }
    }

    private static func running(_ kind: ActivityKind, _ subject: String) -> String {
        switch kind {
        case .fileChange:
            return subject.isEmpty ? String(localized: "Editing files") : String(localized: "Editing \(subject)")
        case .fileRead:
            return subject.isEmpty ? String(localized: "Reading file") : String(localized: "Reading \(subject)")
        case .fileList:
            return subject.isEmpty ? String(localized: "Listing files") : String(localized: "Listing files in \(subject)")
        case .fileSearch:
            return subject.isEmpty ? String(localized: "Searching files") : String(localized: "Searching files for \(subject)")
        case .search:
            return subject.isEmpty ? String(localized: "Searching the web") : String(localized: "Searching the web for \(subject)")
        case .command:
            return subject.isEmpty ? String(localized: "Running command") : String(localized: "Running \(subject)")
        case .plan:
            return String(localized: "Updating plan")
        case .reasoning, .tool, .unknown:
            return subject.isEmpty ? String(localized: "Working") : subject
        }
    }

    private static func completed(_ kind: ActivityKind, _ subject: String) -> String {
        switch kind {
        case .fileChange:
            return subject.isEmpty ? String(localized: "Edited files") : String(localized: "Edited \(subject)")
        case .fileRead:
            return subject.isEmpty ? String(localized: "Read file") : String(localized: "Read \(subject)")
        case .fileList:
            return subject.isEmpty ? String(localized: "Listed files") : String(localized: "Listed files in \(subject)")
        case .fileSearch:
            return subject.isEmpty ? String(localized: "Searched files") : String(localized: "Searched files for \(subject)")
        case .search:
            return subject.isEmpty ? String(localized: "Searched the web") : String(localized: "Searched the web for \(subject)")
        case .command:
            return subject.isEmpty ? String(localized: "Ran command") : String(localized: "Ran \(subject)")
        case .plan:
            return String(localized: "Updated plan")
        case .reasoning, .tool, .unknown:
            return subject.isEmpty ? String(localized: "Used a tool") : subject
        }
    }

    private static func failed(_ kind: ActivityKind, _ subject: String) -> String {
        switch kind {
        case .fileChange:
            return subject.isEmpty ? String(localized: "Failed to edit files") : String(localized: "Failed to edit \(subject)")
        case .fileRead:
            return subject.isEmpty ? String(localized: "Failed to read file") : String(localized: "Failed to read \(subject)")
        case .fileList:
            return subject.isEmpty ? String(localized: "Failed to list files") : String(localized: "Failed to list files in \(subject)")
        case .fileSearch:
            return subject.isEmpty ? String(localized: "Failed to search files") : String(localized: "Failed to search files for \(subject)")
        case .search:
            return subject.isEmpty ? String(localized: "Failed to search the web") : String(localized: "Failed to search the web for \(subject)")
        case .command:
            return subject.isEmpty ? String(localized: "Command failed") : String(localized: "Command failed: \(subject)")
        case .plan:
            return String(localized: "Failed to update plan")
        case .reasoning, .tool, .unknown:
            return subject.isEmpty ? String(localized: "Tool failed") : String(localized: "Failed: \(subject)")
        }
    }
}

extension Int {
    /// "2 minutes 3 seconds" — spelled out, for VoiceOver and for a label with
    /// "1 minute, 30 seconds" — the system's own Duration formatting, so the
    /// plural forms are a locale decision rather than markup in the catalog.
    var durationLabel: String {
        Duration.seconds(Double(self)).formatted(
            .units(allowed: [.hours, .minutes, .seconds], width: .wide, maximumUnitCount: 2)
        )
    }

    /// "2m 3s" — for a row that has to stay on one line. Two units at most,
    /// because the second one is already a rounding detail and the third is
    /// noise: an agent that ran for a day and two hours is not more legible
    /// for also being told the seconds.
    var durationShortLabel: String {
        if self < 60 { return "\(self)s" }
        if self < 3_600 {
            let minutes = self / 60
            let seconds = self % 60
            return seconds > 0 ? "\(minutes)m \(seconds)s" : "\(minutes)m"
        }
        if self < 86_400 {
            let hours = self / 3_600
            let minutes = (self % 3_600) / 60
            return minutes > 0 ? "\(hours)h \(minutes)m" : "\(hours)h"
        }
        let days = self / 86_400
        let hours = (self % 86_400) / 3_600
        return hours > 0 ? "\(days)d \(hours)h" : "\(days)d"
    }
}

extension UInt64 {
    /// A message timestamp in the reader's own locale and calendar.
    var messageTimeLabel: String {
        let date = Date(timeIntervalSince1970: TimeInterval(self))
        let formatter = DateFormatter()
        formatter.dateStyle = Calendar.current.isDateInToday(date) ? .none : .short
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}

extension String {
    /// Flattens a value onto one line. A multi-line command would otherwise
    /// truncate at its first newline, hiding the rest behind no ellipsis at
    /// all — the break is invisible, so the row looks complete when it is not.
    var oneLine: String {
        split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}
