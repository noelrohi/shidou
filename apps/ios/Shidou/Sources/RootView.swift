import ShidouClient
import ShidouProtocol
import SwiftUI

/// The navigation spine from the IA decision: Sessions is the root of a stock
/// `NavigationStack` on iPhone, Settings is a modal stack behind the leading
/// gear. The session list and transcript land with their own slices; what is
/// here is the connection lifecycle wrapped around them.
struct RootView: View {
    @Environment(DaemonConnection.self) private var connection

    @State private var showingSettings = false

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Sessions")
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button {
                            showingSettings = true
                        } label: {
                            Image(systemName: "gearshape")
                        }
                        .accessibilityLabel("Settings")
                    }
                }
        }
        .sheet(isPresented: $showingSettings) {
            NavigationStack {
                DaemonSettingsView()
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { showingSettings = false }
                        }
                    }
            }
            .environment(connection)
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

    @ViewBuilder
    private var content: some View {
        switch connection.presentation {
        case .connectionScreen(let failure):
            PairingView(failure: failure)
        case .repairScreen(let message):
            RepairView(message: message)
        case .inlineIndicator, .silent:
            VStack(spacing: 0) {
                if connection.isDemo { DemoBanner() }
                SessionsPlaceholder()
            }
        }
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

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "play.rectangle")
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("Demo session").font(.footnote.bold())
                Text("Scripted, on Shidou's demo server. Nothing here runs on your computer.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
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

/// Stands in for the session list until its slice lands, and proves the
/// connection end to end: a daemon version on screen means the handshake
/// completed against a real daemon.
private struct SessionsPlaceholder: View {
    @Environment(DaemonConnection.self) private var connection

    var body: some View {
        VStack(spacing: 0) {
            if case .inlineIndicator = connection.presentation {
                ReconnectingBar()
            }
            Spacer()
            VStack(spacing: 10) {
                Image(systemName: "checkmark.circle")
                    .font(.system(size: 40))
                    .foregroundStyle(.green)
                    .accessibilityHidden(true)
                Text("Connected")
                    .font(.title3.bold())
                if let name = connection.saved?.name {
                    Text(name).foregroundStyle(.secondary)
                }
                if let version = connection.daemonVersion {
                    Text("Daemon \(version) · protocol v\(ShidouWire.protocolVersion)")
                        .font(.footnote.monospaced())
                        .foregroundStyle(.tertiary)
                }
                Text("The session list arrives with the next slice.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.top, 8)
            }
            Spacer()
        }
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
            return "Reconnecting to \(host)…"
        }
        return "Reconnecting…"
    }
}
