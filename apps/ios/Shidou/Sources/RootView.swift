import ShidouClient
import ShidouProtocol
import ShidouSession
import SwiftUI

/// The navigation spine. iPad keeps the split view — its sidebar *is* the
/// session list. iPhone drops the sessions page entirely: the task is the
/// screen, and a slide-in drawer (the shape Claude's iOS app normalized) is
/// the task switcher. Nothing open means the most recent task opens.
///
/// Both size classes now carry "which task" the same way — a selection and a
/// draft flag — so crossing the boundary keeps the open task in place.

struct RootView: View {
    @Environment(DaemonConnection.self) private var connection
    @Environment(AttentionCenter.self) private var attention
    @Environment(\.horizontalSizeClass) private var sizeClass

    @State private var showingSettings = false
    /// Bumped on every presentation so Settings gets a fresh `NavigationStack`
    /// and therefore opens at its root every time, rather than resuming
    /// wherever it was left.
    @State private var settingsPresentation = 0
    @State private var selection: UUID?
    @State private var showingDraft = false
    /// iPad only: search pushed onto the sidebar column.
    @State private var showingSearch = false
    /// The task New Task was opened from. Kept separately because presenting
    /// the draft clears `selection`.
    @State private var draftSourceSessionId: UUID?
    /// iPhone only: the drawer over the task screen.
    @State private var showingDrawer = false
    /// Both columns, rather than `.automatic`: with an explicit binding a
    /// `.balanced` split view starts the sidebar hidden in portrait, and a
    /// task list you have to reveal is not the spine the IA decision settled.
    /// Holding it as state is what lets a narrow Stage Manager window that
    /// collapsed the sidebar show it again once the window grows.
    @State private var columnVisibility = NavigationSplitViewVisibility.all

    var body: some View {
        Group {
            switch connection.presentation {
            case .connectionScreen(let failure):
                NavigationStack { PairingView(failure: failure) }
            case .repairScreen(let message):
                NavigationStack { RepairView(message: message) }
            case .inlineIndicator, .silent:
                sessionsSpine
            }
        }
        // The banner rides above the whole spine, because the task it names is
        // by definition not the one on screen.
        .overlay(alignment: .top) {
            if let banner = attention.banner {
                AttentionBannerView(
                    banner: banner,
                    open: {
                        attention.dismissBanner()
                        open(banner.sessionId)
                    },
                    dismiss: { attention.dismissBanner() }
                )
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        // The animation stays *below* the overlay it animates. Applied above
        // it, the implicit animation wraps the navigation stack itself and
        // pushes stop happening at all.
        .animation(.snappy, value: attention.banner)
        // Stage Manager and Split View cross the size-class boundary while a
        // task is open, and both spines hold "which task" in the same places
        // now, so nothing to migrate — only the drawer needs to make sense of
        // a window that just grew a real sidebar.
        .onChange(of: sizeClass) { _, newValue in
            if newValue == .regular {
                showingDrawer = false
            }
        }
        .task(id: connection.sessions.map(ObjectIdentifier.init)) {
            attention.follow(connection.sessions)
        }
        // "Nothing open" is not a state worth a screen. As soon as the catalog
        // lands the app opens the task the user last touched, and only a
        // genuinely empty catalog falls through — to a draft on the phone,
        // where there is no list beside the transcript to explain the blank.
        .onChange(of: taskToAdopt, initial: true) { _, adoption in
            switch adoption {
            case .undecided:
                break
            case .noTasks:
                if sizeClass != .regular { showingDraft = true }
            case .mostRecent(let sessionId):
                selection = sessionId
            }
        }
        // A tapped notification is a request to look at that task, whichever
        // screen the app came back to.
        .onChange(of: attention.openSessionId) { _, sessionId in
            guard let sessionId else { return }
            attention.openSessionId = nil
            open(sessionId)
        }
        .sheet(isPresented: $showingSettings) {
            SettingsStack(presentation: settingsPresentation) { showingSettings = false }
        }
        .alert(
            "This connection is not encrypted",
            isPresented: Binding(
                get: { connection.pendingInsecureWarning != nil },
                set: { if !$0 { connection.acknowledgeInsecureWarning() } }
            )
        ) {
            Button("Continue") { connection.acknowledgeInsecureWarning() }
        } message: {
            Text("The daemon token travels in the clear on your local network. On an untrusted network, connect over Tailscale instead.")
        }
    }

    // MARK: - Spine

    @ViewBuilder
    private var sessionsSpine: some View {
        if sizeClass == .regular {
            // iPad: two columns. The inspector and multitasking behaviour are
            // slice ③; the spine itself is here so the transcript never has to
            // be re-parented later.
            NavigationSplitView(columnVisibility: $columnVisibility) {
                sessionsColumn
                    // A Stage Manager window can be narrower than two usable
                    // columns; pinning the sidebar's range is what keeps the
                    // transcript readable instead of squeezing both.
                    .navigationSplitViewColumnWidth(min: 260, ideal: 320, max: 400)
            } detail: {
                NavigationStack {
                    detailColumn
                }
            }
            // `.balanced` keeps the sidebar beside the transcript rather than
            // overlaying it, which is what a resize should preserve.
            .navigationSplitViewStyle(.balanced)
        } else {
            compactSpine
        }
    }

    // MARK: - The compact spine: task is the screen, drawer is the list

    private var compactSpine: some View {
        SideDrawer(isOpen: $showingDrawer) {
            SessionsDrawer(
                selection: $selection,
                showingDraft: $showingDraft,
                isPresented: $showingDrawer,
                onNewTask: startNewTask
            )
        } content: {
            ZStack(alignment: .top) {
                // The stack exists for the toolbar alone — nothing is ever
                // pushed onto it — but without it the transcript's toolbar
                // items never render, and the surfaces and overflow menus
                // vanish with them.
                NavigationStack {
                    compactRoot
                        .toolbarBackground(.visible, for: .navigationBar)
                }
                if case .inlineIndicator = connection.presentation { ReconnectingBar() }
            }
        }
    }

    @ViewBuilder
    private var compactRoot: some View {
        if showingDraft, selection == nil {
            NewTaskView(sourceSessionId: draftSourceSessionId, opensDrawer: openDrawer)
        } else if let selection {
            TranscriptView(sessionId: selection, opensDrawer: openDrawer)
                .id(selection)
        } else {
            // Only ever a moment long: the catalog is still loading, and the
            // frame it lands on picks the task. A screen that asks the user to
            // choose would be a screen they never needed to see.
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func openDrawer() {
        withAnimation(.interactiveSpring(response: 0.34, dampingFraction: 0.86)) {
            showingDrawer = true
        }
    }

    private var sessionsColumn: some View {
        VStack(spacing: 0) {
            if connection.isDemo { DemoBanner() }
            SessionListView(selection: $selection)
        }
        // Picking a task is how you leave a draft you did not start.
        .onChange(of: selection) { _, newValue in
            if newValue != nil { showingDraft = false }
        }
        .navigationTitle("Sessions")
        .navigationDestination(isPresented: $showingSearch) {
            SearchView(selection: $selection)
        }
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    settingsPresentation += 1
                    showingSettings = true
                } label: {
                    Image(systemName: "gearshape")
                }
                .accessibilityLabel("Settings")
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showingSearch = true
                } label: {
                    Image(systemName: "magnifyingglass")
                }
                .accessibilityLabel("Search tasks")
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    startNewTask()
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("New task")
            }
        }
    }

    /// What the app should open when nothing is open yet.
    ///
    /// Deliberately inert once something *is* open: the guard returns before
    /// any session is read, so a streaming transcript does not invalidate the
    /// spine on every commit.
    private var taskToAdopt: TaskAdoption {
        guard selection == nil, !showingDraft else { return .undecided }
        guard let store = connection.sessions, store.hasLoadedCatalog else { return .undecided }
        guard let recent = store.sessions.max(by: { $0.updatedAt < $1.updatedAt }) else {
            return .noTasks
        }
        return .mostRecent(recent.id)
    }

    /// Shows one task, from wherever the app currently is. Both size classes
    /// read the same state, so this is the whole story again.
    private func open(_ sessionId: UUID) {
        showingDraft = false
        draftSourceSessionId = nil
        selection = sessionId
        withAnimation(.interactiveSpring(response: 0.34, dampingFraction: 0.86)) {
            showingDrawer = false
        }
    }

    private func startNewTask() {
        draftSourceSessionId = selection
        selection = nil
        showingDraft = true
    }

    @ViewBuilder
    private var detailColumn: some View {
        if showingDraft, selection == nil {
            NewTaskView(sourceSessionId: draftSourceSessionId)
        } else if let selection {
            TranscriptView(sessionId: selection)
                .id(selection)
        } else {
            ContentUnavailableView(
                "No task selected",
                systemImage: "text.bubble",
                description: Text("Pick a task on the left, or start one with ＋.")
            )
        }
    }
}

/// What the spine opens on its own when the user has not picked anything.
private enum TaskAdoption: Equatable {
    /// The catalog has not landed yet, or a task is already open.
    case undecided
    case noTasks
    case mostRecent(UUID)
}

/// Settings is a modal stack, reset to root each time it opens. Recreating the
/// `NavigationStack` per presentation is what makes that true without any
/// path bookkeeping.
private struct SettingsStack: View {
    let presentation: Int
    let done: () -> Void

    var body: some View {
        NavigationStack {
            SettingsView(done: done)
        }
        .id(presentation)
    }
}

/// Says what the user is looking at for as long as they are looking at it.
///
/// The Demo Session is convincing on purpose — it streams, it asks for
/// permission, it shows a diff — and a demo that is convincing without
/// saying so is a demo that misleads. It stays on screen rather than
/// appearing once, because the sentence is true the whole time.
struct DemoBanner: View {
    @Environment(DaemonConnection.self) private var connection
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        // At accessibility sizes the row cannot hold the sentence beside the
        // button, and a truncated sentence is the one outcome this banner
        // cannot have: it exists to say the whole thing.
        let layout = typeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
            : AnyLayout(HStackLayout(alignment: .center, spacing: 8))
        layout {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "play.rectangle")
                    .foregroundStyle(.tint)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Demo session").font(.footnote.bold())
                    Text("Scripted, on Shidou's demo server. Nothing here runs on your computer.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if !typeSize.isAccessibilitySize { Spacer(minLength: 8) }
            Button("Exit") { connection.forget() }
                .font(.footnote)
                .buttonStyle(.bordered)
                .accessibilityLabel("Exit the demo")
                .accessibilityHint("Returns to pairing with your own Mac")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.thinMaterial)
        .overlay(alignment: .bottom) { Divider() }
    }
}

/// The middle tier of the connection contract: quiet, inline, and it never
/// takes the screen away from what the user was reading.
private struct ReconnectingBar: View {
    @Environment(DaemonConnection.self) private var connection

    var body: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(label)
                .font(.footnote)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.thinMaterial)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(label)
    }

    private var label: String {
        if let host = connection.connectingAddress {
            return String(localized: "Reconnecting to \(host)…")
        }
        return String(localized: "Reconnecting…")
    }
}
