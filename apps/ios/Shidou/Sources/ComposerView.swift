import PhotosUI
import ShidouProtocol
import ShidouSession
import SwiftUI

/// The composer: everything that sends input to the daemon.
///
/// Structurally this is the web composer's two rows — turn controls inside the
/// box, workspace controls under it — and behaviourally it is the same
/// contract: a draft that materializes on its first prompt, a follow-up that
/// queues behind a running turn, a steer that joins one, and a cancel that is
/// a button rather than a chord you have to know about.
struct ComposerView: View {
    let model: SessionRuntimeModel
    let store: SessionStore
    /// The daemon this composer's preferences belong to; models installed on
    /// one Mac say nothing about another's.
    let daemonAddress: String
    /// Text the transcript wants in the box — quoting a message. Cleared as
    /// soon as it lands, so the same quote can be sent twice.
    var quoted: Binding<String?> = .constant(nil)
    /// A new turn was accepted from this composer. The transcript uses this
    /// moment to place the sent message at the top of the viewport.
    var onTurnSubmitted: () -> Void = {}

    @Environment(AttentionCenter.self) private var attention

    @State private var prompt = ""
    @State private var cursor = 0
    @State private var attachments: [MessageAttachment] = []
    @State private var focused = false
    @State private var inputHeight: CGFloat = 36
    @State private var submitting = false
    @State private var uploading = false
    @State private var dismissedSuggestion: String?
    /// Which suggestion a hardware keyboard has moved to. Touch accepts a row
    /// directly, so this only matters when the arrow keys are driving.
    @State private var highlight = 0
    @State private var actionError: String?
    @State private var preferences = ComposerPreferences()
    @State private var loadedDraftKey: String?

    @State private var sheet: ComposerSheet?
    @State private var photoItem: PhotosPickerItem?
    @State private var showingCamera = false
    @State private var showingPhotos = false

    private enum ComposerSheet: String, Identifiable {
        case model, traits, agentPreset, access, project, workspace, branch, usage
        case browseProject, browseAttachment
        var id: String { rawValue }
    }

    private var session: AgentSession { model.session }
    private var busy: Bool { session.status.isBusy }
    private var draftKey: ComposerDraftKey { .forSession(session) }
    private var hasContent: Bool {
        !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty
    }
    private var canSteer: Bool { session.hasActiveProviderTurn && model.supportsSteer }
    private var started: Bool { session.hasStarted }
    private var project: Project? { store.projects.first { $0.id == session.projectId } }
    private var cwd: String? { store.cwd(for: session) }

    private var selectedModel: ProviderModel? {
        let models = store.probes[session.provider]?.models ?? []
        return models.first { $0.id == session.model }
            ?? models.first { $0.isDefault }
            ?? models.first
    }

    // MARK: - Body

    var body: some View {
        VStack(spacing: 8) {
            if let permission = model.pendingPermission, model.pendingUserInput == nil {
                PermissionPanel(permission: permission) { optionId in
                    run { try await store.respond(model, requestId: permission.requestId, optionId: optionId) }
                }
            }
            if let userInput = model.pendingUserInput {
                UserInputPanel(input: userInput) { answers in
                    run {
                        try await store.respondUserInput(
                            model, requestId: userInput.requestId, answers: answers)
                    }
                }
            }
            if !session.queuedMessages.isEmpty {
                QueuedMessagesView(
                    messages: session.queuedMessages,
                    canSteer: canSteer,
                    edit: editQueued,
                    steer: steerQueued,
                    remove: { message in
                        run { try await store.removeQueuedMessage(model, messageId: message.id) }
                    }
                )
            }
            if suggestionsOpen {
                ComposerSuggestions(
                    rows: suggestionRows, highlight: highlight, accept: accept)
            }
            GlassGroup(spacing: 0) { surface }
            workspaceControls
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 6)
        .floatingBarBackdrop()
        .task(id: draftKeyIdentity) { loadDraft() }
        .onChange(of: quoted.wrappedValue) { _, text in
            guard let text, !text.isEmpty else { return }
            acceptQuote(text)
        }
        .task(id: session.id) { preferences = ComposerPreferenceStore().preferences(for: daemonAddress) }
        .task(id: composerSourcesKey) { store.refreshComposerSources(for: session) }
        .onChange(of: suggestionKey) { _, _ in highlight = 0 }
        .onChange(of: preferences.favoriteModels) { _, _ in
            ComposerPreferenceStore().save(preferences, for: daemonAddress)
        }
        // A blocking prompt takes the keyboard down: the agent is waiting on an
        // answer that would otherwise be behind it.
        .onChange(of: model.pendingPermission?.requestId) { _, requestId in
            if requestId != nil { focused = false }
        }
        .onChange(of: model.pendingUserInput?.requestId) { _, requestId in
            if requestId != nil { focused = false }
        }
        .sheet(item: $sheet) { sheet in
            sheetContent(sheet)
        }
        .photosPicker(isPresented: $showingPhotos, selection: $photoItem, matching: .images)
        .onChange(of: photoItem) { _, item in
            guard let item else { return }
            photoItem = nil
            attachPhoto(item)
        }
        .fullScreenCover(isPresented: $showingCamera) {
            CameraPicker { data, name in
                attach(data: data, mimeType: "image/jpeg", name: name)
            }
            .ignoresSafeArea()
        }
        .alert(
            "Something went wrong",
            isPresented: Binding(
                get: { actionError != nil }, set: { if !$0 { actionError = nil } })
        ) {
            Button("OK") { actionError = nil }
        } message: {
            Text(actionError ?? "")
        }
    }

    // MARK: - The surface

    /// The composer morphs between two shapes, the way T3 Code's mobile
    /// composer does: a single-line pill while it has nothing to say, and a
    /// card — attachments, growing text, and the control row — once it is
    /// focused or holds a draft. The text view is shared by both, so focus
    /// survives the transition and the caret never jumps.
    private var expanded: Bool { focused || hasContent }

    private var surface: some View {
        VStack(alignment: .leading, spacing: 8) {
            if expanded, !attachments.isEmpty {
                attachmentStrip
            }
            HStack(alignment: .center, spacing: 6) {
                ComposerTextView(
                    text: $prompt,
                    selection: $cursor,
                    focused: $focused,
                    height: $inputHeight,
                    placeholder: busy
                        ? String(localized: "Queue a follow-up…")
                        : String(localized: "Ask Shidou to build something…"),
                    maxHeight: 180,
                    suggestionsOpen: suggestionsOpen,
                    onKeyCommand: handle(key:)
                )
                .frame(height: expanded ? inputHeight : 34)
                .onChange(of: prompt) { _, _ in saveDraft() }
                if !expanded {
                    primaryButton
                        .contextMenu { primaryAlternatives }
                }
            }
            if expanded {
                HStack(spacing: 8) {
                    ScrollView(.horizontal) {
                        HStack(spacing: 6) {
                            attachButton
                            modelChip
                            traitsChip
                            agentPresetChip
                            accessChip
                            interactionModeChip
                        }
                        .padding(.vertical, 1)
                    }
                    .scrollIndicators(.hidden)
                    primaryButton
                        .contextMenu { primaryAlternatives }
                }
            }
        }
        .padding(.leading, expanded ? 10 : 14)
        .padding(.trailing, expanded ? 10 : 5)
        .padding(.vertical, expanded ? 10 : 5)
        .glassSurface(
            in: RoundedRectangle(cornerRadius: expanded ? 24 : 999, style: .continuous),
            fallback: AnyShapeStyle(.background.secondary)
        )
        .fallbackBorder(RoundedRectangle(cornerRadius: expanded ? 24 : 999, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: expanded ? 24 : 999, style: .continuous))
        .onTapGesture {
            // A pill is all tap target: touching anywhere in it means "I want
            // to type", which is what expands it.
            if !expanded { focused = true }
        }
        .animation(.snappy(duration: 0.22), value: expanded)
    }

    private var attachmentStrip: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(attachments, id: \.self) { attachment in
                    AttachmentTile(attachment: attachment, store: store) {
                        attachments.removeAll { $0 == attachment }
                        saveDraft()
                    }
                }
            }
            .padding(.vertical, 2)
        }
        .scrollIndicators(.hidden)
    }

    /// Attach joins the card's control row once expanded; the pill has no
    /// room for it and the send/stop control stands in for the row entirely.
    private var attachButton: some View {
        Menu {
            attachmentMenuItems
        } label: {
            Image(systemName: "plus.circle")
                .font(.body.weight(.medium))
                .frame(width: 36, height: 36)
                .contentShape(Rectangle())
        }
        .foregroundStyle(.secondary)
        .disabled(uploading)
        .accessibilityLabel("Attach")
    }

    @ViewBuilder
    private var primaryAlternatives: some View {
        if busy && hasContent {
            Button(canSteer ? "Queue instead" : "Steer current turn") {
                if canSteer { sendOrQueue() } else { steerTurn() }
            }
        }
    }

    /// One button, three states — the web composer's contract: typing with a
    /// turn running steers or queues it, and an empty composer while busy
    /// offers the stop. A second button would just be a second thing to read.
    @ViewBuilder
    private var primaryButton: some View {
        if busy && !hasContent {
            Button(action: stop) {
                Image(systemName: "stop.fill")
                    .frame(width: 36, height: 36)
                    .background(.quaternary, in: Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Stop")
        } else {
            Button(action: primaryAction) {
                Image(systemName: primaryIcon)
                    .fontWeight(.semibold)
                    .foregroundStyle(.white)
                    .frame(width: 36, height: 36)
                    .background(primaryEnabled ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary), in: Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .disabled(!primaryEnabled)
            .keyboardShortcut(.return, modifiers: .command)
            .accessibilityLabel(primaryLabel)
        }
    }

    @ViewBuilder
    private var attachmentMenuItems: some View {
        Button {
            showingPhotos = true
        } label: {
            Label("Photo Library", systemImage: "photo.on.rectangle")
        }
        if CameraPicker.isAvailable {
            Button {
                showingCamera = true
            } label: {
                Label("Take Photo", systemImage: "camera")
            }
        }
        Button {
            sheet = .browseAttachment
        } label: {
            Label("File on the daemon", systemImage: "folder")
        }
    }

    // MARK: - Chips

    private var modelChip: some View {
        ControlChip(action: { sheet = .model }) {
            Text(selectedModel?.name ?? session.model ?? session.provider.displayName)
        }
        .disabled(session.status != .idle)
        .accessibilityLabel("Model: \(selectedModel?.name ?? session.provider.displayName)")
    }

    @ViewBuilder
    private var traitsChip: some View {
        if let model = selectedModel, ComposerTraits.hasAny(model) {
            let fast = ComposerTraits.isFast(session, model)
            ControlChip(
                tint: fast ? .yellow : nil,
                action: { sheet = .traits }
            ) {
                Text(ComposerTraits.chipLabel(session, model))
            }
            .accessibilityLabel("Traits: \(ComposerTraits.chipLabel(session, model))")
        }
    }

    @ViewBuilder
    private var agentPresetChip: some View {
        let presets = store.probes[session.provider]?.agentPresets ?? []
        // The web offers presets only where a provider actually has them, and
        // only before the task has started; anything else would be a control
        // that silently does nothing.
        if session.provider == .deepSeek, !started, session.status == .idle, !presets.isEmpty {
            ControlChip(systemImage: "square.stack.3d.up", action: { sheet = .agentPreset }) {
                Text(
                    AgentPresets.selected(session, presets).map(AgentPresetCopy.label)
                        ?? String(localized: "Standard mode"))
            }
        }
    }

    /// Access and Build/Plan are the two chips a glyph says completely, so the
    /// strip spends its width on the ones it cannot — the model name above all.
    private var accessChip: some View {
        let mode = AccessMode.selected(for: session.runtimeMode)
        return ControlChip(
            systemImage: mode.systemImage, iconOnly: true, action: { sheet = .access }
        ) {
            Text(mode.title)
        }
        .accessibilityLabel("Access: \(mode.title)")
    }

    private var interactionModeChip: some View {
        let plan = session.interactionMode == .plan
        let minimal = session.provider == .deepSeek && session.agentPreset == "minimal"
        let supportsPlan = session.provider != .fx && !minimal
        return ControlChip(
            systemImage: plan ? "list.bullet.clipboard" : "hammer",
            tint: plan ? .accentColor : nil,
            iconOnly: true,
            action: {
                patch { $0.interactionMode = plan ? .build : .plan }
            }
        ) {
            Text(plan ? "Plan" : "Build")
        }
        .disabled(!(plan || supportsPlan))
        .accessibilityLabel(
            plan ? String(localized: "Switch to Build") : String(localized: "Switch to Plan"))
        .accessibilityHint(
            supportsPlan ? "" : String(localized: "This agent does not support Plan"))
    }

    // MARK: - Workspace controls

    /// The toolbar under the surface, styled like a native bottom bar rather
    /// than a second row of pills: quiet caption buttons in the secondary
    /// tint, no borders, with the context gauge pinned at the trailing edge.
    /// The workspace is context, not a control you are about to press — the
    /// row should say where you are, not shout.
    private var workspaceControls: some View {
        let locked = busy || started
        return HStack(spacing: 8) {
            ScrollView(.horizontal) {
                // The container travels with the strip rather than wrapping
                // it: a glass container renders outside the clip of the scroll
                // view it sits above, and the pinned gauge ends up drawn over
                // whichever pill happens to be at the scrolling edge.
                GlassGroup(spacing: 6) {
                    HStack(spacing: 6) {
                        ghostButton(
                            "folder",
                            project.map {
                                $0.isProjectless ? String(localized: "No project") : $0.name
                            } ?? String(localized: "Choose a project"),
                            showsDisclosure: !locked
                        ) { sheet = .project }
                        .disabled(locked)

                        ghostButton(
                            session.workspace.isLocal ? "laptopcomputer" : "arrow.triangle.branch",
                            workspaceLabel,
                            showsDisclosure: !locked
                        ) { sheet = .workspace }
                        .disabled(locked)

                        if project?.isProjectless == false,
                            store.branchSnapshot(for: session) != nil
                        {
                            ghostButton(
                                "arrow.triangle.branch",
                                store.branchSnapshot(for: session)?.displayBranch
                                    ?? String(localized: "Detached HEAD"),
                                showsDisclosure: !busy
                            ) { sheet = .branch }
                            .disabled(busy)
                        }

                        if store.starting.contains(session.id) {
                            Text("Starting agent…")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(.vertical, 1)
            }
            .scrollIndicators(.hidden)
            .clipped()

            GlassGroup(spacing: 0) { usageButton }
        }
    }

    /// The context gauge, pinned outside the scrolling strip: how much of the
    /// window is left is the one thing on this row you should never have to
    /// scroll to find.
    private var usageButton: some View {
        Button { sheet = .usage } label: {
            HStack(spacing: 5) {
                ContextGauge(percent: ContextUsagePresentation.percent(session))
                if let remaining = ContextUsagePresentation.remaining(session) {
                    Text("\(Int(remaining.rounded()))% left")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .glassSurface(
                in: Capsule(),
                interactive: true,
                fallback: AnyShapeStyle(.quaternary.opacity(0.4))
            )
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(usageLabel)
    }

    /// A workspace entry on its own glass pill. The disclosure disappears
    /// when the value is locked, so settled context does not pretend to be a
    /// dropdown.
    private func ghostButton(
        _ icon: String,
        _ label: String,
        showsDisclosure: Bool = true,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.caption2)
                    .accessibilityHidden(true)
                Text(label)
                    .font(.caption)
                    .lineLimit(1)
                if showsDisclosure {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8, weight: .semibold))
                        .accessibilityHidden(true)
                }
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .glassSurface(
                in: Capsule(),
                interactive: true,
                fallback: AnyShapeStyle(.quaternary.opacity(0.4))
            )
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private var workspaceLabel: String {
        switch session.workspace {
        case .newWorktree: return String(localized: "New worktree")
        case .worktree(_, let branch): return branch
        default: return String(localized: "Local")
        }
    }

    private var usageLabel: String {
        guard let percent = ContextUsagePresentation.percent(session) else {
            return String(localized: "Usage")
        }
        return String(localized: "Usage, \(Int(percent.rounded()))% of the context window used")
    }

    // MARK: - Sheets

    @ViewBuilder
    private func sheetContent(_ sheet: ComposerSheet) -> some View {
        switch sheet {
        case .model:
            ModelPickerSheet(
                session: session, store: store, preferences: $preferences
            ) { provider, chosen in
                let remembered = preferences.traits(provider: provider, model: chosen.id)
                patch {
                    $0.provider = provider
                    $0.model = chosen.id
                    $0.reasoningEffort =
                        remembered?.reasoningEffort ?? chosen.defaultReasoningEffort
                    $0.serviceTier = remembered?.serviceTier ?? chosen.defaultServiceTier
                    $0.contextWindow = remembered?.contextWindow ?? chosen.defaultContextWindow
                    if provider != session.provider { $0.agentPreset = nil }
                }
            }
        case .traits:
            if let selectedModel {
                ModelTraitsSheet(session: session, model: selectedModel) { change in
                    patch {
                        switch change {
                        case .reasoningEffort(let value): $0.reasoningEffort = value
                        case .serviceTier(let value): $0.serviceTier = value
                        case .contextWindow(let value): $0.contextWindow = value
                        }
                    }
                }
            }
        case .agentPreset:
            AgentPresetSheet(
                session: session,
                presets: store.probes[session.provider]?.agentPresets ?? []
            ) { preset in
                patch {
                    $0.agentPreset = preset.id
                    if preset.id == "minimal" { $0.interactionMode = .build }
                }
            }
        case .access:
            AccessSheet(session: session) { mode in
                patch { $0.runtimeMode = mode }
            }
        case .project:
            ProjectPickerSheet(
                session: session,
                projects: store.projects,
                onChoose: choose(project:),
                onBrowse: { self.sheet = .browseProject },
                onProjectless: createProjectlessTask
            )
        case .workspace:
            WorkspaceKindSheet(session: session, projectless: project?.isProjectless ?? false) {
                workspace in
                patch { $0.workspace = workspace }
            }
        case .branch:
            if let snapshot = store.branchSnapshot(for: session), let cwd {
                BranchPickerSheet(
                    session: session,
                    snapshot: snapshot,
                    onSelect: { branch in switchBranch(branch, cwd: cwd, create: false) },
                    onCreate: { branch in switchBranch(branch, cwd: cwd, create: true) },
                    onRefresh: { store.refreshBranches(cwd: cwd, force: true) }
                )
            }
        case .usage:
            UsageSheet(session: session, store: store)
        case .browseProject:
            DirectoryBrowserView(mode: .project, store: store) { path in
                do {
                    choose(project: try await store.addProject(path: path))
                    return true
                } catch {
                    actionError = error.localizedDescription
                    return false
                }
            }
        case .browseAttachment:
            DirectoryBrowserView(mode: .attachment, store: store, root: cwd) { path in
                do {
                    add(attachment: try await store.attachDaemonPath(path))
                    return true
                } catch {
                    actionError = error.localizedDescription
                    return false
                }
            }
        }
    }

    // MARK: - Suggestions

    private var trigger: ComposerTrigger? {
        guard focused else { return nil }
        return ComposerAutocomplete.trigger(in: prompt, cursor: cursor)
    }

    private var suggestionKey: String? {
        trigger.map { "\($0.kind):\($0.start):\($0.end):\($0.query)" }
    }

    private var suggestionRows: [ComposerAutocompleteRow] {
        guard let trigger else { return [] }
        return ComposerAutocomplete.rows(
            for: trigger,
            commands: store.commands(for: session),
            files: store.files(for: session)
        )
    }

    private var suggestionsOpen: Bool {
        guard let suggestionKey, suggestionKey != dismissedSuggestion else { return false }
        return !suggestionRows.isEmpty
    }

    /// Arrow keys move the highlight, Return and Tab accept it, Escape closes
    /// the list — the same four keys the web composer binds, reachable here
    /// from a hardware keyboard without the caret leaving the text.
    private func handle(key: ComposerKeyCommand) {
        let rows = suggestionRows
        guard !rows.isEmpty else { return }
        switch key {
        case .previous:
            highlight = (highlight - 1 + rows.count) % rows.count
        case .next:
            highlight = (highlight + 1) % rows.count
        case .accept:
            accept(rows[min(highlight, rows.count - 1)])
        case .dismiss:
            dismissedSuggestion = suggestionKey
        }
    }

    private func accept(_ row: ComposerAutocompleteRow) {
        guard let trigger else { return }
        let replacement = ComposerAutocomplete.replacing(prompt, trigger: trigger, with: row)
        if case .command = row, executeLocalCommand(replacement.text) { return }
        prompt = replacement.text
        cursor = replacement.cursor
        dismissedSuggestion = nil
        highlight = 0
        saveDraft()
    }

    // MARK: - Drafts

    /// Identity of the composer this draft belongs to, so switching tasks (or
    /// a task acquiring an identity) reloads rather than carries text across.
    private var draftKeyIdentity: String {
        switch draftKey {
        case .newSession(let projectId): return "new:\(projectId.uuidString)"
        case .session(let sessionId): return "session:\(sessionId.uuidString)"
        }
    }

    private var composerSourcesKey: String {
        "\(session.provider.rawValue):\(cwd ?? "")"
    }

    /// Puts a quoted message in the box, replacing whatever was there, and
    /// opens the keyboard on it — the same contract as the web prefill.
    private func acceptQuote(_ text: String) {
        prompt = text
        cursor = text.count
        focused = true
        saveDraft()
        quoted.wrappedValue = nil
    }

    private func loadDraft() {
        guard loadedDraftKey != draftKeyIdentity else { return }
        loadedDraftKey = draftKeyIdentity
        let draft = store.draft(for: draftKey)
        prompt = draft.text
        attachments = draft.attachments
        cursor = draft.text.count
    }

    private func saveDraft() {
        store.setDraft(ComposerDraft(text: prompt, attachments: attachments), for: draftKey)
    }

    // MARK: - Actions

    private var primaryEnabled: Bool {
        hasContent && !submitting && !uploading
    }

    private var primaryIcon: String {
        guard busy else { return "arrow.up" }
        return canSteer ? "arrow.turn.down.right" : "text.line.first.and.arrowtriangle.forward"
    }

    private var primaryLabel: String {
        guard busy else { return String(localized: "Send") }
        return canSteer
            ? String(localized: "Steer current turn")
            : String(localized: "Queue a follow-up")
    }
    private func primaryAction() {
        if busy && canSteer { steerTurn() } else { sendOrQueue() }
    }

    /// Sends, or queues behind the turn already running — one call, because
    /// which of the two it is belongs to the store, not to a button.
    private func sendOrQueue() {
        submit { try await store.send($0, to: model) }
    }

    private func steerTurn() {
        submit { try await store.steer($0, to: model) }
    }

    private func submit(
        _ operation: @escaping (ComposerSubmission) async throws -> Void
    ) {
        guard primaryEnabled else { return }
        if executeLocalCommand(prompt) { return }
        // Asking here is asking at the one moment the permission explains
        // itself: something is about to run that the user will want to hear
        // about when they put the phone down.
        attention.requestAuthorizationIfNeeded()
        let text = prompt
        let files = attachments
        let submission = ComposerSubmission(
            prompt: text,
            attachments: files,
            providerPromptOverride: providerPromptOverride(text, files)
        )
        prompt = ""
        cursor = 0
        attachments = []
        dismissedSuggestion = nil
        saveDraft()
        submitting = true
        if !busy { onTurnSubmitted() }
        Task {
            defer { submitting = false }
            do {
                try await operation(submission)
            } catch {
                // Nothing typed is lost to a failed send: it goes back in the
                // box exactly as it was, unless something else was typed since.
                if prompt.isEmpty { prompt = text }
                if attachments.isEmpty { attachments = files }
                saveDraft()
                actionError = error.localizedDescription
            }
        }
    }

    private func providerPromptOverride(
        _ text: String, _ files: [MessageAttachment]
    ) -> String? {
        guard let expanded = ComposerAutocomplete.expandedSubmission(
            provider: session.provider,
            prompt: text.trimmingCharacters(in: .whitespacesAndNewlines),
            commands: store.commands(for: session)
        ) else { return nil }
        let mentions = files.map { "@\($0.mention)" }.joined(separator: " ")
        return [expanded, mentions].filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// Codex's `/fast` never reaches the provider: it flips the service tier
    /// here and clears the box.
    private func executeLocalCommand(_ text: String) -> Bool {
        guard ComposerAutocomplete.isFastModeToggle(
            provider: session.provider, prompt: text, commands: store.commands(for: session))
        else { return false }
        guard let next = ComposerAutocomplete.toggledFastServiceTier(
            current: session.serviceTier, serviceTiers: selectedModel?.serviceTiers ?? [])
        else { return false }
        prompt = ""
        cursor = 0
        dismissedSuggestion = nil
        saveDraft()
        patch { $0.serviceTier = next }
        return true
    }

    private func stop() {
        run { try await store.cancel(model) }
    }

    private func editQueued(_ message: QueuedMessage) {
        prompt = message.visibleContent
        cursor = prompt.count
        attachments = message.attachments
        saveDraft()
        run { try await store.removeQueuedMessage(model, messageId: message.id) }
    }

    private func steerQueued(_ message: QueuedMessage) {
        run {
            try await store.removeQueuedMessage(model, messageId: message.id)
            try await store.steer(
                ComposerSubmission(
                    prompt: message.visibleContent,
                    attachments: message.attachments,
                    providerPromptOverride: message.content
                ),
                to: model
            )
        }
    }

    // MARK: - Attachments

    private func attachPhoto(_ item: PhotosPickerItem) {
        uploading = true
        Task {
            defer { uploading = false }
            do {
                guard let data = try await item.loadTransferable(type: Data.self) else { return }
                let type = item.supportedContentTypes.first
                let name = type?.preferredFilenameExtension.map { "image.\($0)" } ?? "image.png"
                let attachment = try await store.attachImage(
                    data: data,
                    mimeType: type?.preferredMIMEType ?? "image/png",
                    name: name
                )
                add(attachment: attachment)
            } catch {
                actionError = error.localizedDescription
            }
        }
    }

    private func attach(data: Data, mimeType: String, name: String) {
        uploading = true
        Task {
            defer { uploading = false }
            do {
                add(
                    attachment: try await store.attachImage(
                        data: data, mimeType: mimeType, name: name))
            } catch {
                actionError = error.localizedDescription
            }
        }
    }

    private func add(attachment: MessageAttachment) {
        guard !attachments.contains(where: { $0.mention == attachment.mention }) else { return }
        attachments.append(attachment)
        saveDraft()
    }

    // MARK: - Session changes

    private func patch(_ change: (inout AgentSession) -> Void) {
        var next = model.currentProjection
        change(&next)
        if next.model != nil {
            preferences.remember(next)
            ComposerPreferenceStore().save(preferences, for: daemonAddress)
        }
        model.replaceSession(next)
        // A task that has not sent anything is not on the daemon, and
        // configuring one must not put it there: an abandoned New Task has to
        // leave nothing behind. `send` persists it at the moment it becomes
        // real.
        guard next.hasStarted else { return }
        run { try await store.saveSession(next) }
    }

    private func choose(project: Project) {
        let source = draftKey
        patch {
            $0.projectId = project.id
            $0.workspace = project.workspaceDefault.sessionWorkspace
        }
        // The draft follows the task to its new project, so switching does not
        // silently strand what was typed.
        store.moveDraft(from: source, to: .newSession(projectId: project.id))
        loadedDraftKey = nil
        loadDraft()
    }

    private func createProjectlessTask() {
        run {
            let project = try await store.createProjectlessProject()
            choose(project: project)
        }
    }

    private func switchBranch(_ branch: String, cwd: String, create: Bool) {
        // A planned worktree has no checkout yet: picking a branch names the
        // base it will fork from rather than moving anything on disk.
        if !create, case .newWorktree = session.workspace {
            patch { $0.workspace = .newWorktree(baseBranch: branch) }
            return
        }
        run { try await store.checkoutBranch(cwd: cwd, branch: branch, create: create) }
    }

    private func run(_ operation: @escaping () async throws -> Void) {
        Task {
            do {
                try await operation()
            } catch {
                actionError = error.localizedDescription
            }
        }
    }
}
