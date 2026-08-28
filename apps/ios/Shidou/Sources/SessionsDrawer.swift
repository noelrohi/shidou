import ShidouProtocol
import ShidouSession
import SwiftUI

/// The iPhone task switcher — the drawer. The task is the screen, so this
/// slides over it to show what else is open: a New Task button, the demo
/// banner when the connection is the demo, the session list with its recency
/// sections, and Settings at the foot.
///
/// The session list is hosted whole rather than re-created as drawer rows,
/// because rename, delete, refresh, and the empty/error states already live
/// in it and would only drift if repeated here.
struct SessionsDrawer: View {
    @Binding var selection: UUID?
    @Binding var showingDraft: Bool
    @Binding var isPresented: Bool
    let onSettings: () -> Void

    @Environment(DaemonConnection.self) private var connection

    private var store: SessionStore? { connection.sessions }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Shidou")
                    .font(.title2.bold())
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 8)

            newTask

            SessionListView(selection: $selection)
                .onChange(of: selection) { _, newValue in
                    // Picking a task is leaving the drawer — and any draft
                    // that was never started.
                    if newValue != nil {
                        showingDraft = false
                        dismiss()
                    }
                }
                .overlay(alignment: .top) { Divider() }

            footer
        }
    }

    private var newTask: some View {
        Button {
            selection = nil
            showingDraft = true
            dismiss()
        } label: {
            Label("New task", systemImage: "square.and.pencil")
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
        }
        .buttonStyle(.borderedProminent)
        .padding(.horizontal, 16)
        .padding(.bottom, 10)
    }

    private var footer: some View {
        VStack(spacing: 0) {
            Divider()
            Button(action: onSettings) {
                Label("Settings", systemImage: "gearshape")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 12)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 16)
        }
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }

    private func dismiss() {
        withAnimation(.snappy) { isPresented = false }
    }
}
