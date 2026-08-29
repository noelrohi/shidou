import ShidouProtocol
import ShidouSession
import SwiftUI

/// The iPhone task switcher — the drawer's contents. The task is the screen,
/// so this slides over it to show what else is open.
///
/// The list itself is `SessionListView`, hosted whole rather than rebuilt as
/// drawer rows: search, grouping, rename, delete and the empty states already
/// live there and would only drift if repeated here. What the drawer adds is
/// the chrome around it — the wordmark, the demo banner, and a floating bar
/// carrying the two things you reach for without reading: Settings, and a new
/// task.
struct SessionsDrawer: View {
    @Binding var selection: UUID?
    @Binding var showingDraft: Bool
    @Binding var isPresented: Bool
    let onNewTask: () -> Void

    @Environment(DaemonConnection.self) private var connection
    @State private var showingSettings = false
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if connection.isDemo { DemoBanner() }
            SessionListView(selection: $selection)
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
        // An explicit rule rather than `Divider()`, which draws horizontally
        // outside an `HStack` and would lay a line across the list instead of
        // along its edge.
        .overlay(alignment: .trailing) {
            Rectangle()
                .fill(.separator)
                .frame(width: 1 / displayScale)
                .ignoresSafeArea(.container, edges: .vertical)
        }
        .sheet(isPresented: $showingSettings) {
            NavigationStack {
                SettingsView(done: { showingSettings = false })
            }
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Shidou")
                .font(.title2.weight(.semibold))
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 8)
            Button(action: dismiss) {
                Image(systemName: "sidebar.leading")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 32, height: 32)
                    .background(.quaternary.opacity(0.5), in: Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Hide tasks")
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
