import ShidouClient
import ShidouProtocol
import ShidouSession
import SwiftUI

/// The navigation spine from the IA decision: Sessions is the root, the
/// transcript is pushed on top of it, and back-swipe is how you switch tasks.
/// iPad gets the same two surfaces as a split view. No tab bar, no drawer, no
/// palette, no session-switcher sheet.
/// What the iPhone's navigation stack can be showing on top of the list.
///
/// It exists as one type rather than a `UUID` destination beside a boolean
/// one because SwiftUI traps when a `NavigationStack(path:)` carries both.
enum SessionsRoute: Hashable {
    case session(UUID)
    case draft

    var sessionId: UUID? {
        if case .session(let id) = self { return id }
        return nil
    }
}

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
    /// The stack's path, so a tapped notification can push a transcript from
    /// outside the list.
    ///
    /// One route type, not a value destination beside a boolean one: a
    /// `NavigationStack` given both traps inside SwiftUI the moment the value
    /// destination pushes (`NavigationColumnState.boundPathChange`). A draft
    /// is just another thing the stack can hold, so it belongs in the path.
    @State private var path: [SessionsRoute] = []
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
        // task is open, and the two spines hold "which task" in different
        // places — a stack path on iPhone, a list selection on iPad. Carrying
        // it across is what stops a resize from throwing the user back to the
        // list. See the multitasking half of the IA decision (#10).
        .onChange(of: sizeClass) { _, newValue in
            if newValue == .regular {
                selection = path.last?.sessionId ?? selection
                showingDraft = path.contains(.draft)
                path = []
            } else {
                path = selection.map { [.session($0)] } ?? (showingDraft ? [.draft] : [])
                selection = nil
            }
        }
        .task(id: connection.sessions.map(ObjectIdentifier.init)) {
            attention.follow(connection.sessions)
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
                sessionsColumn(selectsInPlace: true)
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
            NavigationStack(path: $path) {
                sessionsColumn(selectsInPlace: false)
                    .navigationDestination(for: SessionsRoute.self) { route in
                        switch route {
                        case .session(let id): TranscriptView(sessionId: id)
                        case .draft: NewTaskView()
                        }
                    }
            }
        }
    }

    private func sessionsColumn(selectsInPlace: Bool) -> some View {
        VStack(spacing: 0) {
            if connection.isDemo { DemoBanner() }
            if case .inlineIndicator = connection.presentation { ReconnectingBar() }
            SessionListView(selection: $selection, selectsInPlace: selectsInPlace)
        }
        // Picking a task is how you leave a draft you did not start.
        .onChange(of: selection) { _, newValue in
            if newValue != nil { showingDraft = false }
        }
        .navigationTitle("Sessions")
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
                    selection = nil
                    if sizeClass == .regular {
                        showingDraft = true
                    } else {
                        path.append(.draft)
                    }
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("New task")
            }
        }
    }

    /// Shows one task, from wherever the app currently is.
    private func open(_ sessionId: UUID) {
        showingDraft = false
        if sizeClass == .regular {
            selection = sessionId
        } else {
            selection = nil
            path = [.session(sessionId)]
        }
    }

    @ViewBuilder
    private var detailColumn: some View {
        if showingDraft, selection == nil {
            NewTaskView()
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
private struct DemoBanner: View {
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
