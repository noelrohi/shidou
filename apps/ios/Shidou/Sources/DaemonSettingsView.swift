import ShidouClient
import ShidouProtocol
import SwiftUI

/// Settings → Daemon: what the phone is paired with, how it is connected, and
/// the two escape hatches (re-pair, forget).
///
/// The rest of the settings pages land with their own slice; this is the page
/// the connection lifecycle owns.
struct DaemonSettingsView: View {
    @Environment(DaemonConnection.self) private var connection
    @Environment(\.dismiss) private var dismiss

    @State private var isRepairing = false
    @State private var confirmingForget = false

    var body: some View {
        Form {
            if let saved = connection.saved {
                Section {
                    LabeledContent("Name", value: saved.name ?? "Unnamed")
                    LabeledContent("Status") { StatusLabel(phase: connection.phase) }
                    if let version = connection.daemonVersion {
                        LabeledContent("Daemon", value: version)
                    }
                    LabeledContent("Protocol", value: "v\(ShidouWire.protocolVersion)")
                } header: {
                    Text(saved.isDemo ? "Demo daemon" : "Paired Mac")
                } footer: {
                    if saved.isDemo {
                        Text("A public server running a scripted session. Nothing in it runs on your computer, and nothing you send it is executed.")
                    }
                }

                Section {
                    ForEach(saved.orderedAddresses(), id: \.self) { address in
                        AddressRow(
                            address: address,
                            isLastGood: address == saved.lastGoodAddress
                        )
                    }
                } header: {
                    Text("Addresses")
                } footer: {
                    Text("Tried in this order. The one that last worked leads.")
                }

                if connection.showsInsecureBadge {
                    Section {
                        Label {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Token sent in the clear").font(.footnote.bold())
                                Text("At least one address is a plain ws:// connection outside your Mac and your tailnet. Anyone on that network can read the token.")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                        } icon: {
                            Image(systemName: "lock.open.trianglebadge.exclamationmark")
                                .foregroundStyle(.orange)
                        }
                    }
                }

                Section {
                    if saved.isDemo {
                        // No "pair again" for the demo: its token is baked
                        // into the build, so there is nothing to re-scan.
                        // Leaving returns to the pairing screen, which is
                        // where a real Mac gets connected.
                        Button("Leave the demo", role: .destructive) { confirmingForget = true }
                    } else {
                        Button("Pair again…") { isRepairing = true }
                        Button("Forget this Mac", role: .destructive) { confirmingForget = true }
                    }
                }
            } else {
                Section {
                    Text("No Mac paired yet.")
                        .foregroundStyle(.secondary)
                }
            }

            // Guideline 5.1.1 wants the privacy policy reachable from inside
            // the app, and this is the only settings surface until the settings
            // slice lands — move it to the About page when that arrives.
            // See issue #16.
            Section("About") {
                Link(destination: URL(string: "https://shidou.dev/privacy")!) {
                    LabeledContent("Privacy Policy") {
                        Image(systemName: "arrow.up.right")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                .accessibilityHint("Opens shidou.dev in Safari")
            }
        }
        .navigationTitle("Daemon")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $isRepairing) {
            NavigationStack {
                RepairView(
                    message: "Scan the code in Settings → Daemon on your Mac.",
                    onPaired: { isRepairing = false }
                )
                    .navigationTitle("Pair again")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Cancel") { isRepairing = false }
                        }
                    }
            }
            .environment(connection)
        }
        .confirmationDialog(
            connection.isDemo ? "Leave the demo?" : "Forget this Mac?",
            isPresented: $confirmingForget,
            titleVisibility: .visible
        ) {
            Button(connection.isDemo ? "Leave" : "Forget", role: .destructive) {
                connection.forget()
                dismiss()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            if connection.isDemo {
                Text("Nothing is deleted — the demo holds nothing of yours. You can start it again from the pairing screen.")
            } else {
                Text("The token is deleted from this phone. Your sessions stay on the Mac.")
            }
        }
    }
}

private struct AddressRow: View {
    let address: CandidateAddress
    let isLastGood: Bool

    var body: some View {
        HStack {
            Text(address.raw)
                .font(.footnote.monospaced())
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            if isLastGood {
                // Paired with text, never color alone.
                Label("Last used", systemImage: "checkmark.circle.fill")
                    .labelStyle(.titleAndIcon)
                    .font(.caption2)
                    .foregroundStyle(.green)
            }
            if address.isTrustedTransport {
                Image(systemName: "lock.fill")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Encrypted transport")
            }
        }
    }
}

private struct StatusLabel: View {
    let phase: ConnectionPhase

    var body: some View {
        Label(text, systemImage: symbol)
            .labelStyle(.titleAndIcon)
            .font(.footnote)
            .foregroundStyle(tint)
    }

    private var text: String {
        switch phase {
        case .connected: return "Connected"
        case .connecting: return "Connecting…"
        case .backingOff: return "Reconnecting…"
        case .failed(let failure): return failure.message
        case .idle: return "Not connected"
        }
    }

    private var symbol: String {
        switch phase {
        case .connected: return "checkmark.circle.fill"
        case .connecting, .backingOff: return "arrow.triangle.2.circlepath"
        case .failed: return "exclamationmark.triangle.fill"
        case .idle: return "moon.zzz"
        }
    }

    private var tint: Color {
        switch phase {
        case .connected: return .green
        case .connecting, .backingOff: return .secondary
        case .failed: return .orange
        case .idle: return .secondary
        }
    }
}
