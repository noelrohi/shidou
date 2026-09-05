import Foundation
import ShidouProtocol

// Row assembly and label formatting for the transcript, ported from the web
// client's `transcript.tsx` and `lib/transcript-presentation.ts`.
//
// Kept out of the views for two reasons: a row builder runs for every visible
// row on every frame, so the whole-session work has to be hoisted somewhere it
// happens once; and this is where the transcript's rules live, which makes it
// the part worth testing headlessly.

/// One row of the transcript, in display order.
public enum TranscriptRow: Identifiable, Sendable {
    /// The collapsed work of a settled turn — reasoning and tool activity that
    /// happened before the visible answer.
    case fold(key: String, turn: AgentTurn)
    case activities(key: String, block: TranscriptBlock, isLive: Bool)
    case message(key: String, MessageRow)
    /// Recorded edits for a settled turn without an answer to attach them to.
    case changed(key: String, turnId: UUID, recordedEdits: RecordedEdits)
    case working(startedAt: UInt64)

    public var id: String {
        switch self {
        case .fold(let key, _), .activities(let key, _, _), .message(let key, _),
            .changed(let key, _, _):
            return key
        case .working:
            return "working"
        }
    }

    /// The turn this row belongs to, when it belongs to one.
    var turnId: UUID? {
        switch self {
        case .fold(_, let turn):
            return turn.id
        case .activities(_, let block, _):
            return block.turnId
        case .message(_, let row):
            return row.message.turnId
        case .changed(_, let turnId, _):
            return turnId
        case .working:
            return nil
        }
    }
}

public struct MessageRow: Sendable {
    public var message: Message
    public var index: Int
    /// The first message of the session, which carries no separator above it.
    public var isFirst: Bool
    /// A user message that starts a follow-up rather than the session.
    public var startsFollowUp: Bool
    /// The desktop attaches one footer to the terminal assistant part of each
    /// settled turn; its time is the turn's completion time.
    public var footer: AssistantResponseFooter?
    /// Provider-recorded edits belonging to this answer's turn.
    public var recordedEdits: RecordedEdits?
    /// The turn a fork would keep, when this answer can be forked from.
    public var forkTurnCount: Int?
    /// The turn a rewind would rewrite, when this prompt can be sent again.
    public var rewindTurnCount: Int?
}

public struct AssistantResponseFooter: Hashable, Sendable {
    public var content: String
    public var timestamp: UInt64
}

public enum TranscriptPresentation {
    /// Build every row of a session, honouring which turn folds are expanded.
    ///
    /// This is the whole-session pass: it runs once when the projection
    /// publishes, never inside a row builder.
    /// `retainedTurnCounts` are the turns the daemon still holds a checkpoint
    /// ref for; without them no rewind is offered, because a rewind with
    /// nothing to restore is a promise the workspace cannot keep.
    public static func rows(
        _ session: AgentSession,
        expandedTurns: Set<UUID> = [],
        retainedTurnCounts: Set<Int> = [],
        recordedEdits: [UUID: RecordedEdits]? = nil
    ) -> [TranscriptRow] {
        let turnsById = Dictionary(session.turns.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let raw = rawRows(session)
        let folds = turnFolds(session, raw)
        let footers = assistantResponseFooters(session)
        let (inlineEdits, standaloneEdits) = editCards(
            session, summaries: recordedEdits ?? RecordedEdits.summaries(in: session)
        )

        var rows: [TranscriptRow] = []
        var seenUserMessage = false
        for row in raw {
            if let fold = folds.anchors[row.key] {
                rows.append(.fold(key: "fold-\(fold.id.wireString)", turn: fold))
            }
            if folds.hidden.contains(row.key),
                let turnId = row.turnId, !expandedTurns.contains(turnId)
            {
                continue
            }
            switch row.content {
            case .block(let block, let index):
                let liveTurn = block.turnId.flatMap { turnsById[$0]?.status } == .running
                rows.append(.activities(
                    key: row.key,
                    block: block,
                    isLive: liveTurn
                        && index + 1 == session.transcriptBlocks.count
                        && block.afterMessage == session.messages.count
                ))
            case .message(let message, let index):
                let startsFollowUp = message.role == .user && seenUserMessage
                if message.role == .user { seenUserMessage = true }
                let turn = message.turnId.flatMap { turnsById[$0] }
                let footer = footers[index]
                rows.append(.message(key: row.key, MessageRow(
                    message: message,
                    index: index,
                    isFirst: index == 0,
                    startsFollowUp: startsFollowUp,
                    footer: footer,
                    recordedEdits: inlineEdits[index],
                    forkTurnCount: footer == nil
                        ? nil
                        : responseForkTurnCount(session, message: message, turn: turn),
                    rewindTurnCount: userMessageRewindTurnCount(
                        session, message: message, retainedTurnCounts: retainedTurnCounts
                    )
                )))
            }
        }

        rows = insertStandaloneEdits(rows, standaloneEdits)

        if session.status.isBusy,
            let running = session.turns.last(where: { $0.status == .running })
        {
            rows.append(.working(startedAt: running.startedAt))
        }
        return rows
    }

    // MARK: - Raw rows

    private struct RawRow {
        enum Content {
            case block(TranscriptBlock, index: Int)
            case message(Message, index: Int)
        }
        var key: String
        var turnId: UUID?
        var content: Content
    }

    private static func rawRows(_ session: AgentSession) -> [RawRow] {
        var blocksByAnchor: [Int: [(block: TranscriptBlock, index: Int)]] = [:]
        for (index, block) in session.transcriptBlocks.enumerated() {
            let anchor = min(block.afterMessage, session.messages.count)
            blocksByAnchor[anchor, default: []].append((block, index))
        }
        var rows: [RawRow] = []
        for index in 0...session.messages.count {
            for entry in blocksByAnchor[index] ?? [] {
                rows.append(RawRow(
                    key: "block-\(entry.index)",
                    turnId: entry.block.turnId,
                    content: .block(entry.block, index: entry.index)
                ))
            }
            guard index < session.messages.count else { break }
            let message = session.messages[index]
            rows.append(RawRow(
                key: "message-\(message.id.wireString)",
                turnId: message.turnId,
                content: .message(message, index: index)
            ))
        }
        return rows
    }

    // MARK: - Folds

    /// A settled turn's work — everything before its visible answer — collapses
    /// behind one row, the same boundary the desktop uses.
    private static func turnFolds(
        _ session: AgentSession,
        _ rows: [RawRow]
    ) -> (hidden: Set<String>, anchors: [String: AgentTurn]) {
        var rowsByTurn: [UUID: [RawRow]] = [:]
        for row in rows {
            guard let turnId = row.turnId else { continue }
            if case .message(let message, _) = row.content, message.role != .assistant { continue }
            rowsByTurn[turnId, default: []].append(row)
        }
        var hidden: Set<String> = []
        var anchors: [String: AgentTurn] = [:]
        for turn in session.turns where turn.status != .running {
            let turnRows = rowsByTurn[turn.id] ?? []
            let answerStart = answerStartIndex(turnRows)
            let work = turnRows.prefix(answerStart)
            guard let first = work.first else { continue }
            anchors[first.key] = turn
            for row in work { hidden.insert(row.key) }
        }
        return (hidden, anchors)
    }

    /// Where the answer begins: everything up to the last uninterrupted run of
    /// assistant text at the end of the turn is work.
    private static func answerStartIndex(_ rows: [RawRow]) -> Int {
        func isAnswerText(_ row: RawRow) -> Bool {
            guard case .message(let message, _) = row.content else { return false }
            return !message.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        guard let lastText = rows.lastIndex(where: isAnswerText) else { return rows.count }
        let lastNonText = rows[..<lastText].lastIndex(where: { !isAnswerText($0) })
        return lastNonText.map { $0 + 1 } ?? 0
    }

    // MARK: - Fork and rewind

    /// The turn a fork would keep, or `nil` where forking would mislead.
    ///
    /// A fork replays the kept turns into a new session through the provider's
    /// own resume, so it needs a cursor that belongs to the provider still
    /// selected, a turn the provider actually started, and a session that has
    /// stopped moving. Any of those missing and the answer is no.
    public static func responseForkTurnCount(
        _ session: AgentSession,
        message: Message,
        turn: AgentTurn?
    ) -> Int? {
        guard message.role == .assistant,
            session.status == .idle || session.status == .failed,
            let cursor = session.providerCursor,
            cursor["provider"]?.stringValue == session.provider.rawValue,
            let turn, turn.providerTurnStarted
        else { return nil }
        return turn.turnCount
    }

    /// The turn a rewind would rewrite, or `nil` where the workspace could not
    /// be put back.
    ///
    /// Rewinding restores the checkpoint taken before this prompt, so the ref
    /// has to still exist. Rolling back turns the provider has already run
    /// also needs a cursor to resume from; without one the transcript would
    /// move and the provider's own history would not.
    public static func userMessageRewindTurnCount(
        _ session: AgentSession,
        message: Message,
        retainedTurnCounts: Set<Int>
    ) -> Int? {
        guard message.role == .user,
            session.status == .idle || session.status == .failed,
            let turnId = message.turnId,
            let turn = session.turns.first(where: { $0.id == turnId })
        else { return nil }
        let retained = max(0, turn.turnCount - 1)
        guard retainedTurnCounts.contains(retained) else { return nil }
        let rollbackTurns = session.turns.dropFirst(retained).filter(\.providerTurnStarted).count
        if rollbackTurns > 0 && session.providerCursor == nil { return nil }
        return turn.turnCount
    }

    // MARK: - Footers

    /// One footer per settled turn, on its terminal assistant message. Its
    /// value is the whole visible answer, not merely the final chunk.
    static func assistantResponseFooters(_ session: AgentSession) -> [Int: AssistantResponseFooter] {
        var footers: [Int: AssistantResponseFooter] = [:]
        var lastAssistantByTurn: [UUID: Int] = [:]
        var answerByTurn: [UUID: [String]] = [:]
        for (index, message) in session.messages.enumerated() {
            guard message.role == .assistant, let turnId = message.turnId else { continue }
            lastAssistantByTurn[turnId] = index
            let content = message.content.trimmingCharacters(in: .whitespacesAndNewlines)
            if !content.isEmpty { answerByTurn[turnId, default: []].append(content) }
        }
        for turn in session.turns where turn.status != .running {
            guard let index = lastAssistantByTurn[turn.id],
                let parts = answerByTurn[turn.id], !parts.isEmpty
            else { continue }
            footers[index] = AssistantResponseFooter(
                content: parts.joined(separator: "\n\n"),
                timestamp: turn.completedAt ?? session.messages[index].createdAt
            )
        }
        return footers
    }

    // MARK: - Recorded edits

    private static func editCards(
        _ session: AgentSession,
        summaries: [UUID: RecordedEdits]
    ) -> (inline: [Int: RecordedEdits], standalone: [UUID: RecordedEdits]) {
        var lastAssistantByTurn: [UUID: Int] = [:]
        for (index, message) in session.messages.enumerated() {
            if message.role == .assistant, let turnId = message.turnId {
                lastAssistantByTurn[turnId] = index
            }
        }
        var inline: [Int: RecordedEdits] = [:]
        var standalone: [UUID: RecordedEdits] = [:]
        for turn in session.turns {
            guard turn.status != .running,
                let edits = summaries[turn.id],
                !edits.files.isEmpty
            else { continue }
            if let index = lastAssistantByTurn[turn.id],
                !session.messages[index].content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            {
                inline[index] = edits
            } else {
                standalone[turn.id] = edits
            }
        }
        return (inline, standalone)
    }

    private static func insertStandaloneEdits(
        _ rows: [TranscriptRow],
        _ standalone: [UUID: RecordedEdits]
    ) -> [TranscriptRow] {
        guard !standalone.isEmpty else { return rows }
        var lastIndexByTurn: [UUID: Int] = [:]
        for (index, row) in rows.enumerated() {
            guard let turnId = row.turnId, standalone[turnId] != nil else { continue }
            lastIndexByTurn[turnId] = index
        }
        var afterIndex: [Int: [(UUID, RecordedEdits)]] = [:]
        for (turnId, edits) in standalone {
            guard let index = lastIndexByTurn[turnId] else { continue }
            afterIndex[index, default: []].append((turnId, edits))
        }
        guard !afterIndex.isEmpty else { return rows }
        var out: [TranscriptRow] = []
        out.reserveCapacity(rows.count + standalone.count)
        for (index, row) in rows.enumerated() {
            out.append(row)
            for (turnId, edits) in (afterIndex[index] ?? []).sorted(by: {
                $0.0.wireString < $1.0.wireString
            }) {
                out.append(.changed(
                    key: "changed-\(turnId.wireString)", turnId: turnId, recordedEdits: edits
                ))
            }
        }
        return out
    }
}
