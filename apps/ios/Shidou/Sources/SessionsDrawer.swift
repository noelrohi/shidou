import ShidouProtocol
import ShidouSession
import SwiftUI

/// The iPhone task switcher — the drawer's contents. The task is the screen,
/// so this slides over it to show what else is open.
///
/// The list itself is `SessionListView`, hosted whole rather than rebuilt as
/// drawer rows: grouping, rename, delete and the empty states already live
/// there and would only drift if repeated here. What the drawer adds is the
/// chrome around it — the mark and wordmark, a search button that covers the
/// screen with `SearchView`, the demo banner, and a floating bar carrying the
/// two things you reach for without reading: Settings, and a new task.
///
/// There is no close button: the task showing past the drawer's edge is the
/// way back, by tap or by drag, the same as Claude's drawer.
struct SessionsDrawer: View {
    @Binding var selection: UUID?
    @Binding var showingDraft: Bool
    @Binding var isPresented: Bool
    let onNewTask: () -> Void

    @Environment(DaemonConnection.self) private var connection
    @State private var showingSettings = false
    @State private var showingSearch = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if connection.isDemo { DemoBanner() }
            // The stack exists for the Projects push. Its bar stays hidden
            // at the root, where the drawer's own header is the chrome, and
            // comes back on the pushed screens, which need a way home.
            NavigationStack {
                SessionListView(selection: $selection)
                    .toolbar(.hidden, for: .navigationBar)
            }
                .onChange(of: selection) { _, newValue in
                    // Picking a task is leaving the drawer — and any draft
                    // that was never started.
                    if newValue != nil {
                        showingDraft = false
                        dismiss()
                    }
                }
            footer
        }
        .background {
            Rectangle()
                .fill(.background)
                .ignoresSafeArea(.container, edges: .vertical)
        }
        .sheet(isPresented: $showingSettings) {
            NavigationStack {
                SettingsView(done: { showingSettings = false })
            }
        }
        // A cover rather than a push: search is its own screen with the
        // keyboard up and a field at the bottom, and a sheet's grabber would
        // sit in the way of the empty state it centres.
        .fullScreenCover(isPresented: $showingSearch) {
            SearchView(selection: $selection)
        }
    }

    private var header: some View {
        HStack(spacing: 16) {
            // The web sidebar's lockup, at the same size: the app icon at
            // 24 points with a 6-point radius beside the wordmark.
            HStack(spacing: 8) {
                Image("AppIconMark")
                    .resizable()
                    .scaledToFill()
                    .frame(width: 24, height: 24)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .accessibilityHidden(true)
                Text("Shidou")
                    .font(.title.weight(.semibold))
                    .accessibilityAddTraits(.isHeader)
            }
            Spacer(minLength: 0)
            Button { showingSearch = true } label: {
                Image(systemName: "magnifyingglass")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .frame(width: 36, height: 36)
                    .glassSurface(
                        in: Circle(),
                        interactive: true,
                        fallback: AnyShapeStyle(.quaternary.opacity(0.5))
                    )
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Search tasks")
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 12)
    }

    /// Settings and New Task sit outside the list's UIKit scroll surface so
    /// the controls own their whole hit regions.
    private var footer: some View {
        GlassGroup(spacing: 10) {
            HStack(spacing: 10) {
                Button(action: { showingSettings = true }) {
                    Image(systemName: "gearshape")
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .frame(width: 44, height: 44)
                        .glassSurface(
                            in: Circle(),
                            interactive: true,
                            fallback: AnyShapeStyle(.thickMaterial)
                        )
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Settings")

                ConnectionDot()

                Spacer(minLength: 0)

                Button(action: newTask) {
                    Label("New task", systemImage: "square.and.pencil")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 16)
                        .frame(height: 44)
                        .glassSurface(
                            in: Capsule(),
                            tint: .accentColor,
                            interactive: true,
                            fallback: AnyShapeStyle(Color.accentColor)
                        )
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 10)
    }

    private func newTask() {
        onNewTask()
        dismiss()
    }

    private func dismiss() {
        withAnimation(.interactiveSpring(response: 0.34, dampingFraction: 0.86)) {
            isPresented = false
        }
    }
}

/// The connection, said in the one place the drawer always shows. Colour alone
/// would be meaningless to anyone who cannot see it, so the state is spelled
/// out in the accessibility label rather than implied by the fill.
private struct ConnectionDot: View {
    @Environment(DaemonConnection.self) private var connection

    var body: some View {
        Circle()
            .fill(fill)
            .frame(width: 7, height: 7)
            .accessibilityLabel(label)
    }

    private var fill: AnyShapeStyle {
        switch connection.presentation {
        case .silent: return AnyShapeStyle(.green)
        case .inlineIndicator: return AnyShapeStyle(.orange)
        case .connectionScreen, .repairScreen: return AnyShapeStyle(.red)
        }
    }

    private var label: String {
        switch connection.presentation {
        case .silent: return String(localized: "Connected")
        case .inlineIndicator: return String(localized: "Reconnecting")
        case .connectionScreen, .repairScreen: return String(localized: "Disconnected")
        }
    }
}
