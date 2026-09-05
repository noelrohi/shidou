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
    /// Set on iPhone, where the drawer is the task switcher and this button
    /// is its only door. iPad's split view has a real sidebar, so it leaves
    /// this nil and the item does not appear.
    var opensDrawer: (() -> Void)?
    /// Starts a task from this one. Nil on a draft: there is nothing newer
    /// than the task that does not exist yet.
    var onNewTask: (() -> Void)?

    init(sessionId: UUID, opensDrawer: (() -> Void)? = nil, onNewTask: (() -> Void)? = nil) {
        self.source = .existing(sessionId)
        self.opensDrawer = opensDrawer
        self.onNewTask = onNewTask
    }

    init(draft: AgentSession, opensDrawer: (() -> Void)? = nil) {
        self.source = .draft(draft)
        self.opensDrawer = opensDrawer
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
    @State private var mermaid = MermaidStore()
    @State private var expandedTurns: Set<UUID> = []
    @State private var expandedActivities: Set<UUID> = []
    @State private var reviewRowKey: String?
    @State private var reviewRequests = 0
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
    @State private var images = TranscriptImageStore()
    /// The prompt being edited, and the turn sending it would rewind to.
    @State private var editing: MessageEdit?
    /// A fork or rewind the daemon completed with a complaint, or one that
    /// failed outright. Either way the user asked for it and deserves to hear.
    @State private var historyNotice: String?
    /// Text the transcript has handed the composer to quote.
    @State private var quoted: String?
    /// A send waits for the store to publish its new user row, then anchors
    /// that row at the viewport top like the desktop transcript.
    @State private var pendingSubmissionAnchor: PendingSubmissionAnchor?
    @State private var submittedMessageAnchor: String?
    /// Heights only for rows in the submitted turn. Keeping them per row lets
    /// the outer LazyVStack stay virtualized even when one turn is very long.
    @State private var anchoredRowHeights: [String: CGFloat] = [:]
    /// The transcript's end has scrolled below the composer — the
    /// scroll-to-latest button's whole reason to exist. Reported by
    /// `onScrolledAwayFromBottom` on the scroll view, so it is written only
    /// when it flips. The bottom-anchored open starts at rest, so the
    /// button starts hidden.
    @State private var isAwayFromLatest = false
    /// One past each press of the scroll-to-latest button. A count, not a
    /// boolean, so two presses in a row both land; the scroller watches it
    /// because the `ScrollViewProxy` lives there, not on the composer bar.
    @State private var scrollToLatestRequests = 0

    private struct PendingSubmissionAnchor: Equatable {
        let token = UUID()
        let previousMessageId: UUID?
    }

    private struct MessageEdit: Equatable {
        var messageId: UUID
        var turnCount: Int
        var content: String
    }

    private var store: SessionStore? { connection.sessions }

    var body: some View {
        // The panel wraps the *content*, not the chrome: an `.inspector`
        // applied over `.toolbar` swallows the transcript's toolbar items on
        // iPad, and the panel button is one of them.
        panelPresenter(content)
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
        .alert(
            "Task history",
            isPresented: Binding(
                get: { historyNotice != nil },
                set: { if !$0 { historyNotice = nil } }
            )
        ) {
            Button("OK", role: .cancel) { historyNotice = nil }
        } message: {
            Text(historyNotice ?? "")
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
        let rows = TranscriptPresentation.rows(
            model.session,
            expandedTurns: expandedTurns,
            retainedTurnCounts: store?.retainedTurnCounts(for: model.session.id) ?? [],
            recordedEdits: model.recordedEdits
        )
        let matches = isFinding
            ? TranscriptFind.matches(in: rows, query: query)
            : TranscriptFind.Result(matches: [], limited: false)
        return VStack(spacing: 0) {
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
            Group {
                if rows.isEmpty && !model.session.hasStarted {
                    // A draft has no transcript to scroll. Asking the question
                    // reads better than an empty scroll view, and it leaves the
                    // composer the rest of the screen.
                    NewTaskCanvas(
                        project: store?.projects.first { $0.id == model.session.projectId })
                } else {
                    scroller(rows: rows, matches: matches, model: model)
                }
            }
            // The composer is a bottom bar, not the last row of a stack: as a
            // bar the transcript keeps scrolling underneath it and the bar's
            // blur fades what passes behind, the same way the navigation bar
            // treats the top of the screen. Stacked, it would sit on an opaque
            // slab and the transcript would simply stop above it.
            .floatingBottomBar {
                if let store {
                    VStack(spacing: 0) {
                        if isAwayFromLatest {
                            ScrollToLatestButton { scrollToLatestRequests += 1 }
                                .padding(.bottom, 8)
                                .transition(.opacity.combined(with: .scale(scale: 0.85)))
                        }
                        ComposerView(
                            model: model,
                            store: store,
                            daemonAddress: connection.preferenceKey,
                            quoted: $quoted,
                            onTurnSubmitted: {
                                pendingSubmissionAnchor = PendingSubmissionAnchor(
                                    previousMessageId: latestUserMessageId(in: model.session))
                            }
                        )
                    }
                    // The button joins and leaves the bar rather than toggling
                    // in place: the composer is the bar's last element, so it
                    // never moves — the bar just grows upward. Reduce Motion
                    // keeps the swap and drops the animation.
                    .animation(reduceMotion ? nil : .snappy(duration: 0.22), value: isAwayFromLatest)
                }
            }
        }
        // Markdown images resolve against the workspace this transcript reads,
        // and the recursive block views take it from here rather than each
        // forwarding three more parameters.
        .environment(\.transcriptImages, TranscriptImageContext(
            images: images,
            store: store,
            workspaceCwd: store?.cwd(for: model.session)
        ))
        // Which prompts can be sent again changes when a turn settles, and
        // never mid-turn. Asking once per settle keeps `git` off every frame.
        .task(id: settledTurnCount(model)) {
            store?.refreshTurnRefs(for: model.session, force: true)
        }
    }

    /// How many turns have finished. The identity of the turn-refs refresh:
    /// it moves exactly when a new checkpoint could exist.
    private func settledTurnCount(_ model: SessionRuntimeModel) -> Int {
        model.session.turns.filter { $0.status != .running }.count
    }

    /// The virtualized transcript itself, exactly as the rendering decision
    /// settled it: bottom-anchored, lazy, and dismissing the keyboard as the
    /// user scrolls away from the composer.
    private func scroller(
        rows: [TranscriptRow],
        matches: TranscriptFind.Result,
        model: SessionRuntimeModel
    ) -> some View {
        GeometryReader { viewport in
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 16) {
                        transcriptRows(
                            rows,
                            model: model,
                            viewportHeight: viewport.size.height
                        )
                    }
                    // On iOS 17 the scroll-anchor API cannot separate initial
                    // placement from keyboard-driven size changes. Bottom-align
                    // short content here and scroll long content once on open,
                    // so later viewport changes can preserve what is being read.
                    .frame(
                        minHeight: max(0, viewport.size.height - 24),
                        alignment: .bottom
                    )
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                }
                .transcriptDefaultScrollAnchor()
                .scrollDismissesKeyboard(.interactively)
                .dismissesKeyboardOnTap()
                .accessibilityIdentifier("transcript-scroll")
                // The web counts anything within its Virtuoso's 100 px
                // `atBottomThreshold` as resting at the bottom; the same
                // slop keeps the button from flickering while the pinned
                // tail drifts a few points under streaming updates.
                .onScrolledAwayFromBottom(threshold: 100) { isAwayFromLatest = $0 }
                .onAppear {
                    anchorSubmittedMessage(in: rows, with: proxy)
                    if #unavailable(iOS 18.0), pendingSubmissionAnchor == nil {
                        Task { @MainActor in
                            await Task.yield()
                            proxy.scrollTo("transcript-tail", anchor: .bottom)
                        }
                    }
                }
                .onChange(of: latestUserMessageId(in: model.session)) {
                    reconcileSubmittedMessageAnchor(in: rows)
                    anchorSubmittedMessage(in: rows, with: proxy)
                }
                .onChange(of: reviewRequests) {
                    guard let reviewRowKey else { return }
                    proxy.scrollTo(reviewRowKey, anchor: .top)
                }
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
                .onChange(of: scrollToLatestRequests) {
                    // A jump, not a journey: the web button scrolls
                    // `behavior: 'auto'` and the desktop's is equally direct.
                    // Animating through a LazyVStack materializes every row
                    // the flight passes, for a delay the tap was trying to
                    // skip. The tail is the last element in both layouts, so
                    // landing on it bottom-anchored is the resting position
                    // whatever the submitted-turn reservation is doing below.
                    proxy.scrollTo("transcript-tail", anchor: .bottom)
                }
            }
        }
    }

    @ViewBuilder
    private func transcriptRows(
        _ rows: [TranscriptRow],
        model: SessionRuntimeModel,
        viewportHeight: CGFloat
    ) -> some View {
        if let submittedMessageAnchor,
            let anchorIndex = rows.firstIndex(where: { $0.id == submittedMessageAnchor })
        {
            ForEach(rows[..<anchorIndex]) { row in
                rowView(row, model: model)
                    .id(row.id)
            }
            ForEach(rows[anchorIndex...]) { row in
                rowView(row, model: model)
                    .id(row.id)
                    .onGeometryChange(for: CGFloat.self) { geometry in
                        geometry.size.height
                    } action: { height in
                        anchoredRowHeights[row.id] = height
                    }
            }
            // A short response needs room below it or ScrollView clamps the
            // new prompt back to the bottom. This reservation shrinks as the
            // visible rows of the active turn fill the viewport.
            Color.clear
                .frame(height: anchorEndSpace(
                    for: rows[anchorIndex...], viewportHeight: viewportHeight))
                .id("transcript-tail")
        } else {
            ForEach(rows) { row in
                rowView(row, model: model)
                    .id(row.id)
            }
            // Keeps the last row clear of the composer's top edge.
            Color.clear.frame(height: 8).id("transcript-tail")
        }
    }

    /// Accepted Turn replaces the optimistic message id. Carry the scroll
    /// anchor and its measured height to the canonical row so the prompt does
    /// not jump when its identity converges.
    private func reconcileSubmittedMessageAnchor(in rows: [TranscriptRow]) {
        guard pendingSubmissionAnchor == nil,
            let submittedMessageAnchor,
            !rows.contains(where: { $0.id == submittedMessageAnchor }),
            let latest = latestUserMessage(in: rows)
        else { return }
        self.submittedMessageAnchor = latest.rowId
        if let height = anchoredRowHeights.removeValue(forKey: submittedMessageAnchor) {
            anchoredRowHeights[latest.rowId] = height
        }
    }

    private func anchorSubmittedMessage(
        in rows: [TranscriptRow],
        with proxy: ScrollViewProxy
    ) {
        guard let pendingSubmissionAnchor,
            let latest = latestUserMessage(in: rows),
            latest.messageId != pendingSubmissionAnchor.previousMessageId
        else { return }

        self.pendingSubmissionAnchor = nil
        submittedMessageAnchor = latest.rowId
        anchoredRowHeights = [:]
        Task { @MainActor in
            await Task.yield()
            proxy.scrollTo(latest.rowId, anchor: .top)
        }
    }

    private func anchorEndSpace(
        for rows: ArraySlice<TranscriptRow>,
        viewportHeight: CGFloat
    ) -> CGFloat {
        let measuredHeight = rows.reduce(CGFloat(8)) { height, row in
            height + (anchoredRowHeights[row.id] ?? 0)
        }
        let spacing = CGFloat(max(0, rows.count - 1)) * 16
        return max(0, viewportHeight - measuredHeight - spacing)
    }

    private func latestUserMessage(in rows: [TranscriptRow]) -> (rowId: String, messageId: UUID)? {
        rows.reversed().compactMap { row in
            guard case .message(let key, let messageRow) = row,
                messageRow.message.role == .user
            else { return nil }
            return (key, messageRow.message.id)
        }.first
    }

    private func latestUserMessageId(in session: AgentSession) -> UUID? {
        session.messages.last { $0.role == .user }?.id
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
            ActivityGroupRow(
                block: block,
                isLive: isLive,
                backgroundWork: model.backgroundWork,
                images: images,
                store: store,
                onOpenBackgroundWork: { key in
                    surfacePath = [.work(key: key)]
                    showingSurfaces = true
                },
                expandedActivities: $expandedActivities
            )
        case .message(_, let messageRow):
            if messageRow.message.role == .user {
                if let editing, editing.messageId == messageRow.message.id {
                    MessageEditBubble(
                        initialContent: editing.content,
                        pending: store?.rewinding[model.session.id] != nil,
                        onCancel: { self.editing = nil },
                        onSubmit: { text in rewind(model, turnCount: editing.turnCount, prompt: text) }
                    )
                } else {
                    UserMessageRow(
                        message: messageRow.message,
                        images: images,
                        store: store,
                        rewindTurnCount: messageRow.rewindTurnCount,
                        isRewinding: store?.rewinding[model.session.id] != nil,
                        onEdit: { turnCount in
                            editing = MessageEdit(
                                messageId: messageRow.message.id,
                                turnCount: turnCount,
                                content: messageRow.message.visibleContent
                            )
                        },
                        onQuote: { quoted = $0 }
                    )
                }
            } else {
                AssistantMessageRow(
                    row: messageRow,
                    markdown: markdown,
                    highlights: highlights,
                    mermaid: mermaid,
                    workspaceCwd: store?.cwd(for: model.session),
                    onOpenFile: openFileLink,
                    isForking: store?.forking.contains(model.session.id) ?? false,
                    onFork: { turnCount in fork(model, turnCount: turnCount) },
                    onQuote: { quoted = $0 },
                    onReviewChanges: messageRow.message.turnId.map { turnId in
                        { reviewChanges(model, turnId: turnId) }
                    }
                )
            }
        case .changed(_, let turnId, let edits):
            RecordedEditsSummary(edits: edits) {
                reviewChanges(model, turnId: turnId)
            }
        case .working(let startedAt):
            WorkingRow(
                startedAt: startedAt, now: now, isWaiting: model.session.status == .waiting
            )
        }
    }

    // MARK: - History

    /// Starts a new task from this answer and opens it. The daemon builds the
    /// session; the phone's part is to go there, because a fork nobody is
    /// looking at is indistinguishable from nothing happening.
    private func fork(_ model: SessionRuntimeModel, turnCount: Int) {
        guard let store else { return }
        Task {
            do {
                let forked = try await store.forkFromResponse(model, turnCount: turnCount)
                if let warning = forked.checkpointWarning {
                    historyNotice = String(
                        localized: "Forked, but the workspace checkpoint could not be restored: \(warning)"
                    )
                }
                attention.openSessionId = forked.session.id
            } catch {
                historyNotice = error.localizedDescription
            }
        }
    }

    /// Rewinds to a prompt and sends it again. The edit bubble closes only on
    /// success: a rewind that failed leaves the text where the user can try
    /// again rather than losing it.
    private func rewind(_ model: SessionRuntimeModel, turnCount: Int, prompt: String) {
        guard let store else { return }
        Task {
            do {
                let warning = try await store.rewindToMessage(
                    model, turnCount: turnCount, prompt: prompt
                )
                editing = nil
                if let warning {
                    historyNotice = String(
                        localized: "Rewound, but some checkpoints could not be cleaned up: \(warning)"
                    )
                }
            } catch {
                historyNotice = error.localizedDescription
            }
        }
    }

    private func reviewChanges(_ model: SessionRuntimeModel, turnId: UUID) {
        guard let edits = model.recordedEdits[turnId] else { return }
        expandedTurns.insert(turnId)
        expandedActivities.formUnion(edits.activityIds)
        reviewRowKey = edits.firstRowKey
        reviewRequests += 1
    }

    // MARK: - Chrome

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        if let opensDrawer {
            ToolbarItem(placement: .topBarLeading) {
                Button(action: opensDrawer) {
                    // A hamburger, not a sidebar glyph: on iPhone this opens a
                    // drawer over the task rather than revealing a column
                    // beside it, and the sidebar symbol promises the latter.
                    Image(systemName: "line.3.horizontal")
                }
                .keyboardShortcut("s", modifiers: [.command, .control])
                .accessibilityLabel("Tasks")
            }
        }
        if let model, let snapshot = store?.workspace(for: model.session),
            snapshot.additions > 0 || snapshot.deletions > 0
        {
            // Keep the diffstat out of the hamburger's glass group so each
            // reads as its own control, like the web header's loose pair.
            if #available(iOS 26.0, *) {
                ToolbarSpacer(.fixed, placement: .topBarLeading)
            }
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    showingSurfaces.toggle()
                } label: {
                    HStack(spacing: 3) {
                        Text(verbatim: "+\(snapshot.additions)")
                            .foregroundStyle(.green)
                        Text(verbatim: "−\(snapshot.deletions)")
                            .foregroundStyle(.red)
                    }
                    .font(.footnote.monospacedDigit())
                }
                .accessibilityLabel("Diff stat")
                .accessibilityValue(
                    "\(snapshot.additions) added, \(snapshot.deletions) removed")
            }
        }
        if let onNewTask {
            ToolbarItem(placement: .topBarTrailing) {
                Button(action: onNewTask) {
                    Image(systemName: "plus")
                }
                .keyboardShortcut("n", modifiers: .command)
                .accessibilityLabel("New task")
            }
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
            showingSurfaces.toggle()
        } label: {
            Label("Files and changes", systemImage: "info.circle")
        }
        .disabled(model.flatMap { store?.cwd(for: $0.session) } == nil)
        .keyboardShortcut("0", modifiers: .command)
        .accessibilityHint("Opens files, changes, visuals and background work")
        Divider()
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


extension View {
    /// Opens short transcripts at the bottom without treating every later
    /// viewport change as a command to move there. In particular, the keyboard
    /// and a growing composer shrink the viewport; applying the bottom anchor
    /// to that size change pushes the row being read above the screen.
    @ViewBuilder
    func transcriptDefaultScrollAnchor() -> some View {
        if #available(iOS 18.0, *) {
            defaultScrollAnchor(.bottom, for: .initialOffset)
                .defaultScrollAnchor(.bottom, for: .alignment)
        } else {
            self
        }
    }
}

private struct ScrollBottomState: Equatable {
    let isScrollable: Bool
    let isAway: Bool
}

/// Reports whether this scroll view's content rests more than `threshold`
/// points above its bottom edge — the state behind the scroll-to-latest
/// button. The measurement rides `onScrollGeometryChange`, which is an iOS 18
/// API; below it there is nothing to read the scroll position from, so the
/// modifier degrades to silence rather than a button that guesses.
extension View {
    @ViewBuilder
    func onScrolledAwayFromBottom(
        threshold: CGFloat,
        onChange: @escaping (Bool) -> Void
    ) -> some View {
        if #available(iOS 18.0, *) {
            onScrollGeometryChange(for: ScrollBottomState.self) { geometry in
                let isScrollable = geometry.contentSize.height > geometry.containerSize.height
                return ScrollBottomState(
                    isScrollable: isScrollable,
                    isAway: isScrollable
                        && geometry.visibleRect.maxY < geometry.contentSize.height - threshold
                )
            } action: { _, state in
                onChange(state.isAway)
            }
        } else {
            self
        }
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

/// What a new task looks like before it is one: the web app's question, asked
/// where its transcript will be.
///
/// The web names the project inside the sentence and makes it the picker. Here
/// the sentence only says it — the composer's project chip is directly below,
/// and two controls for one choice, a thumb's width apart, is the worse phone
/// screen.
private struct NewTaskCanvas: View {
    let project: Project?

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "sparkles")
                .font(.title2)
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
            Text(question)
                .font(.title3.weight(.medium))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Text("Attach files with @, run a command with /.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 32)
        .padding(.bottom, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }

    /// No project is a real state — the scratch workspace, or a catalog that
    /// has not landed yet — and "build in nothing" is not a question, so it
    /// drops the clause rather than naming a placeholder.
    private var question: String {
        guard let project, !project.isProjectless else {
            return String(localized: "What should we build?")
        }
        return String(localized: "What should we build in \(project.name)?")
    }
}

/// The jump back to the live tail: a 32 pt circle over the composer's top
/// edge — the same size, inset and arrow the web (`size-8`, `bottom-2`) and
/// the desktop (32 px, `bottom(8)`) already ship — centered, because the
/// composer spans the width and its trailing corner is the send button's
/// neighborhood. It floats over arbitrary content, so it takes the
/// composer's own glass surface — interactive, because it is a control —
/// with the composer pill's material fallback and hairline below iOS 26.
private struct ScrollToLatestButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "arrow.down")
                .font(.system(size: 14, weight: .semibold))
                .frame(width: 32, height: 32)
                .glassSurface(
                    in: Circle(),
                    interactive: true,
                    fallback: AnyShapeStyle(.background.secondary)
                )
                .fallbackBorder(Circle())
                // The glyph's circle is the visual; the hit area is the
                // larger rectangle around it.
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity)
        .accessibilityLabel(String(localized: "Scroll to bottom"))
        .accessibilityHint(String(localized: "Returns to the newest message"))
    }
}
