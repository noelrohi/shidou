import ShidouProtocol
import ShidouSession
import SwiftUI

/// The transcript, built exactly as the rendering decision settled it and the
/// on-device prototype confirmed: `ScrollView` + `LazyVStack` +
/// `defaultScrollAnchor(.bottom)`, markdown parsed incrementally, and the
/// projection republished on an 80 ms cadence so a token-rate stream cannot
/// invalidate SwiftUI per event.
struct TranscriptView: View {
    /// A transcript is opened one of two ways: from the list, where the daemon
    /// has the session and it must be hydrated; or from ＋, where the task is
    /// still a local draft with nothing on the daemon to fetch.
    enum Source {
        case existing(UUID)
        case draft(AgentSession)

        var sessionId: UUID {
            switch self {
            case .existing(let id): return id
            case .draft(let session): return session.id
            }
        }
    }

    let source: Source

    init(sessionId: UUID) {
        self.source = .existing(sessionId)
    }

    init(draft: AgentSession) {
        self.source = .draft(draft)
    }

    private var sessionId: UUID { source.sessionId }

    @Environment(DaemonConnection.self) private var connection
    @Environment(AttentionCenter.self) private var attention
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.horizontalSizeClass) private var sizeClass

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
    /// The Surfaces Sheet's own navigation path, held here so a transcript
    /// link can open it *already* at a file, and so the path survives the
    /// sheet becoming an inspector when the size class changes.
    @State private var showingSurfaces = false
    @State private var surfacePath: [SurfaceRoute] = []
    @State private var showingCommit = false
    @State private var now = UInt64(Date().timeIntervalSince1970)

    private var store: SessionStore? { connection.sessions }

    var body: some View {
        // The panel wraps the *content*, not the chrome: an `.inspector`
        // applied over `.toolbar` swallows the transcript's toolbar items on
        // iPad, and the panel button is one of them.
        panelPresenter(content)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbar }
    }

    private var content: some View {
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
        .task { await load() }
        // Nothing about the task on screen is ever announced: the user is
        // already looking at it.
        .onAppear { attention.visibleSessionId = sessionId }
        .onDisappear {
            if attention.visibleSessionId == sessionId { attention.visibleSessionId = nil }
        }
        .task(id: model?.session.status) { await tickWhileWorking() }
        .alert("Rename task", isPresented: $showingRename) {
            TextField("Title", text: $renameText)
            Button("Cancel", role: .cancel) {}
            Button("Rename") { rename() }
        }
        .sheet(isPresented: $showingCommit) {
            if let model, let cwd = store?.cwd(for: model.session), let store {
                CommitSheet(session: model.session, store: store, cwd: cwd)
            }
        }
    }

    /// The panel, in whichever container the current width calls for.
    ///
    /// The two are branched rather than both attached with gated bindings,
    /// because `.inspector` on a view pushed into a `NavigationStack` stops
    /// that stack pushing at all on iPhone — the transcript simply never
    /// opens. Branching keeps `.inspector` out of the compact spine entirely.
    @ViewBuilder
    private func panelPresenter(_ content: some View) -> some View {
        if sizeClass == .regular {
            content.inspector(isPresented: $showingSurfaces) {
                surfaces.inspectorColumnWidth(min: 320, ideal: 380, max: 520)
            }
        } else {
            content.sheet(isPresented: $showingSurfaces) {
                surfaces
                    .presentationDetents([.large])
                    .presentationDragIndicator(.visible)
            }
        }
    }

    @ViewBuilder
    private var surfaces: some View {
        if let model, let store {
            SurfacesView(
                session: model.session, model: model, store: store, path: $surfacePath)
        }
    }

    /// A tapped file link opens the panel at that file. A path outside the
    /// workspace has no surface to open — the surfaces read one workspace, not
    /// the daemon host's whole filesystem — so it opens the panel at the tree
    /// rather than pretending.
    private func openFileLink(_ route: TranscriptLinkRoute) {
        surfacePath = SurfaceRoute.path(for: route) ?? [.files]
        showingSurfaces = true
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
            if rows.isEmpty && !model.session.hasStarted {
                // A draft has no transcript to scroll. Saying what to do reads
                // better than an empty scroll view, and it leaves the composer
                // the rest of the screen.
                EmptyDraftPrompt()
            } else {
                scroller(rows: rows, matches: matches, model: model)
            }
            if let store {
                ComposerView(
                    model: model, store: store, daemonAddress: connection.preferenceKey)
            }
        }
    }

    /// The virtualized transcript itself, exactly as the rendering decision
    /// settled it: bottom-anchored, lazy, and dismissing the keyboard as the
    /// user scrolls away from the composer.
    private func scroller(
        rows: [TranscriptRow],
        matches: TranscriptFind.Result,
        model: SessionRuntimeModel
    ) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    ForEach(rows) { row in
                        rowView(row, model: model)
                            .id(row.id)
                    }
                    // Keeps the last row clear of the composer's top edge.
                    Color.clear.frame(height: 8).id("transcript-tail")
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .defaultScrollAnchor(.bottom)
            .scrollDismissesKeyboard(.interactively)
            .dismissesKeyboardOnTap()
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
                    onOpenFile: openFileLink
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
        if case .draft = source, model?.session.hasStarted != true {
            return String(localized: "New task")
        }
        return model.map { displayTitle($0.session) }
            ?? store?.sessions.first { $0.id == sessionId }.map(displayTitle)
            ?? String(localized: "Task")
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Button {
                showingSurfaces.toggle()
            } label: {
                Image(systemName: "sidebar.right")
            }
            .disabled(model.flatMap { store?.cwd(for: $0.session) } == nil)
            .keyboardShortcut("0", modifiers: .command)
            .accessibilityLabel("Files and changes")
            .accessibilityHint("Opens files, changes, visuals and background work")
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
            if store?.cwd(for: model.session) != nil {
                Divider()
                Button {
                    showingCommit = true
                } label: {
                    Label("Commit…", systemImage: "arrow.up.circle")
                }
                .keyboardShortcut("k", modifiers: [.command, .shift])
            }
        }
    }

    // MARK: - Actions

    private func load() async {
        guard model == nil, let store else { return }
        switch source {
        case .draft(let session):
            // Nothing to hydrate: the task exists only here until its first
            // prompt, which is what the draft contract means.
            model = store.adopt(session)
            loadError = nil
        case .existing(let id):
            do {
                model = try await store.open(id)
                loadError = nil
            } catch {
                loadError = error.localizedDescription
            }
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
                        Text(verbatim: "·").foregroundStyle(.quaternary).accessibilityHidden(true)
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


/// Tapping through a view also puts the keyboard away. The transcript is the
/// composer's outside, and a tap there is an unambiguous "done typing" —
/// scrolling already dismisses interactively, but a tap is what people try
/// first. It resigns whatever is first responder through the responder chain,
/// so the wrapped composer text view and the find bar both obey, and the
/// gesture is simultaneous, so row buttons and file links still get the touch.
extension View {
    func dismissesKeyboardOnTap() -> some View {
        simultaneousGesture(TapGesture().onEnded {
            UIApplication.shared.sendAction(
                #selector(UIResponder.resignFirstResponder), to: nil, from: nil,
                for: nil)
        })
    }
}

/// A task with nothing in it yet. It says what to do rather than showing an
/// empty scroll view, and it leaves the composer the whole rest of the screen.
private struct EmptyDraftPrompt: View {
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "square.and.pencil")
                .font(.largeTitle)
                .foregroundStyle(.tertiary)
            Text("Start a new task")
                .font(.headline)
            Text("Describe what you want built. Attach files with @, run a command with /.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }
}
