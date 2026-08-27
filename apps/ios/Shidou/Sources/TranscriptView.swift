import ShidouProtocol
import ShidouSession
import SwiftUI

/// The transcript, built exactly as the rendering decision settled it and the
/// on-device prototype confirmed: `ScrollView` + `LazyVStack` +
/// `defaultScrollAnchor(.bottom)`, markdown parsed incrementally, and the
/// projection republished on an 80 ms cadence so a token-rate stream cannot
/// invalidate SwiftUI per event.
struct TranscriptView: View {
    let sessionId: UUID

    @Environment(DaemonConnection.self) private var connection
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var model: SessionRuntimeModel?
    @State private var loadError: String?
    @State private var markdown = MarkdownStore()
    @State private var highlights = HighlightStore()
    @State private var expandedTurns: Set<UUID> = []
    @State private var isFinding = false
    @State private var query = ""
    @State private var currentMatch: Int?
    @State private var showingRename = false
    @State private var renameText = ""
    @State private var now = UInt64(Date().timeIntervalSince1970)

    private var store: SessionStore? { connection.sessions }

    var body: some View {
        Group {
            if let model {
                transcript(model)
            } else if let loadError {
                ContentUnavailableView {
                    Label("Could not open this task", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(loadError)
                } actions: {
                    Button("Try again") { Task { await load() } }
                }
            } else {
                ProgressView("Opening…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbar }
        .task { await load() }
        .task(id: model?.session.status) { await tickWhileWorking() }
        .alert("Rename task", isPresented: $showingRename) {
            TextField("Title", text: $renameText)
            Button("Cancel", role: .cancel) {}
            Button("Rename") { rename() }
        }
    }

    // MARK: - Content

    private func transcript(_ model: SessionRuntimeModel) -> some View {
        let rows = TranscriptPresentation.rows(model.session, expandedTurns: expandedTurns)
        let matches = isFinding
            ? TranscriptFind.matches(in: rows, query: query)
            : TranscriptFind.Result(matches: [], limited: false)
        return VStack(spacing: 0) {
            HeaderSubtitle(session: model.session, store: store)
            if isFinding {
                FindBar(
                    query: $query,
                    matchCount: matches.matches.count,
                    limited: matches.limited,
                    current: currentMatch,
                    step: { backward in
                        currentMatch = TranscriptFind.step(
                            current: currentMatch, count: matches.matches.count, backward: backward
                        )
                    },
                    close: {
                        isFinding = false
                        query = ""
                        currentMatch = nil
                    }
                )
            }
            if model.isCatchingUp { CatchingUpBar() }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 16) {
                        ForEach(rows) { row in
                            rowView(row, model: model)
                                .id(row.id)
                        }
                        // Anchors the bottom above the safe area, and gives
                        // slice ②'s composer somewhere to sit without the last
                        // row disappearing under it.
                        Color.clear.frame(height: 24).id("transcript-tail")
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                }
                .defaultScrollAnchor(.bottom)
                .scrollDismissesKeyboard(.interactively)
                .onChange(of: currentMatch) { _, index in
                    guard let index, index < matches.matches.count else { return }
                    let key = matches.matches[index].rowKey
                    // Scrolling to a match is navigation, but animating the
                    // journey is decoration, and Reduce Motion asks for none.
                    if reduceMotion {
                        proxy.scrollTo(key, anchor: .center)
                    } else {
                        withAnimation { proxy.scrollTo(key, anchor: .center) }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func rowView(_ row: TranscriptRow, model: SessionRuntimeModel) -> some View {
        switch row {
        case .fold(_, let turn):
            TurnFoldRow(turn: turn, expanded: expandedTurns.contains(turn.id)) {
                if expandedTurns.contains(turn.id) {
                    expandedTurns.remove(turn.id)
                } else {
                    expandedTurns.insert(turn.id)
                }
            }
        case .activities(_, let block, let isLive):
            ActivityGroupRow(block: block, isLive: isLive)
        case .message(_, let messageRow):
            if messageRow.message.role == .user {
                UserMessageRow(message: messageRow.message)
            } else {
                AssistantMessageRow(
                    row: messageRow,
                    markdown: markdown,
                    highlights: highlights,
                    workspaceCwd: store?.cwd(for: model.session),
                    onOpenFile: { _ in }
                )
            }
        case .changed(_, _, let checkpoint):
            CheckpointSummary(checkpoint: checkpoint)
        case .working(let startedAt):
            WorkingRow(
                startedAt: startedAt, now: now, isWaiting: model.session.status == .waiting
            )
        }
    }

    // MARK: - Chrome

    private var title: String {
        model.map { displayTitle($0.session) }
            ?? store?.sessions.first { $0.id == sessionId }.map(displayTitle)
            ?? String(localized: "Task")
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Button {
                // Inert until the Surfaces Sheet lands in slice ③. Shown now
                // so the header does not re-lay-out when it starts working.
            } label: {
                Image(systemName: "sidebar.right")
            }
            .disabled(true)
            .accessibilityLabel("Files and changes")
            .accessibilityHint("Available in a later version")
        }
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                overflowMenuContents
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .accessibilityLabel("More")
        }
    }

    @ViewBuilder
    private var overflowMenuContents: some View {
        Button {
            isFinding = true
            currentMatch = nil
        } label: {
            Label("Find in transcript", systemImage: "magnifyingglass")
        }
        Button {
            renameText = model.map { displayTitle($0.session) } ?? ""
            showingRename = true
        } label: {
            Label("Rename", systemImage: "pencil")
        }
        if let model {
            Button {
                UIPasteboard.general.string = transcriptPlainText(model.session)
            } label: {
                Label("Copy transcript", systemImage: "doc.on.doc")
            }
        }
    }

    // MARK: - Actions

    private func load() async {
        guard model == nil, let store else { return }
        do {
            model = try await store.open(sessionId)
            loadError = nil
        } catch {
            loadError = error.localizedDescription
        }
    }

    private func rename() {
        let title = renameText
        guard let store else { return }
        Task { try? await store.rename(sessionId, to: title) }
    }

    /// One clock for the whole screen, ticking only while a turn runs. A timer
    /// per row would wake the phone once per row per second for the same
    /// second.
    private func tickWhileWorking() async {
        guard model?.session.status.isBusy == true else { return }
        while !Task.isCancelled, model?.session.status.isBusy == true {
            now = UInt64(Date().timeIntervalSince1970)
            try? await Task.sleep(for: .seconds(1))
        }
    }

    private func transcriptPlainText(_ session: AgentSession) -> String {
        session.messages
            .map { "\($0.role == .user ? "You" : "Agent"): \($0.visibleContent)" }
            .joined(separator: "\n\n")
    }
}

/// Project, branch and diff stat under the title. Read straight from the
/// store: a miss means the background probe has not landed yet, and the
/// header simply shows less rather than blocking a frame on `git`.
private struct HeaderSubtitle: View {
    let session: AgentSession
    let store: SessionStore?

    var body: some View {
        if !parts.isEmpty {
            HStack(spacing: 6) {
                ForEach(Array(parts.enumerated()), id: \.offset) { index, part in
                    if index > 0 {
                        Text("·").foregroundStyle(.quaternary).accessibilityHidden(true)
                    }
                    Text(part)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 4)
            .accessibilityElement(children: .combine)
        }
    }

    private var parts: [String] {
        var parts: [String] = []
        if let project = store?.project(for: session) { parts.append(project.name) }
        guard let snapshot = store?.workspace(for: session) else { return parts }
        parts.append(snapshot.branch)
        if snapshot.additions > 0 || snapshot.deletions > 0 {
            parts.append("+\(snapshot.additions) −\(snapshot.deletions)")
        }
        return parts
    }
}

/// Replay or a refetch is in flight, so the transcript on screen is not yet
/// the whole story. Saying so beats letting a half-applied transcript look
/// finished.
private struct CatchingUpBar: View {
    var body: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.mini)
            Text("Catching up…")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .background(.thinMaterial)
        .accessibilityElement(children: .combine)
    }
}

private struct FindBar: View {
    @Binding var query: String
    let matchCount: Int
    let limited: Bool
    let current: Int?
    let step: (Bool) -> Void
    let close: () -> Void

    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            TextField("Find in transcript", text: $query)
                .textFieldStyle(.plain)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .focused($focused)
                .submitLabel(.next)
                .onSubmit { step(false) }
            Text(countLabel)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .accessibilityLabel(countLabel)
            Button { step(true) } label: { Image(systemName: "chevron.up") }
                .disabled(matchCount == 0)
                .accessibilityLabel("Previous match")
            Button { step(false) } label: { Image(systemName: "chevron.down") }
                .disabled(matchCount == 0)
                .accessibilityLabel("Next match")
            Button("Done", action: close)
                .font(.footnote)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
        .onAppear { focused = true }
    }

    private var countLabel: String {
        guard matchCount > 0 else { return query.isEmpty ? "" : String(localized: "No matches") }
        let position = (current ?? 0) + 1
        return limited ? "\(position)/\(matchCount)+" : "\(position)/\(matchCount)"
    }
}
