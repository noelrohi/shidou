import ShidouClient
import SwiftUI

/// The connection screen: shown when the phone has never paired, and again
/// whenever the connection reaches a dead end retrying cannot fix.
struct PairingView: View {
    @Environment(DaemonConnection.self) private var connection

    let failure: ConnectionFailure?

    @State private var isScanning = false
    @State private var isEnteringManually = false
    @State private var error: String?

    var body: some View {
        // Short content centres; at large Dynamic Type sizes it outgrows the
        // screen and the ScrollView takes over.
        GeometryReader { proxy in
            ScrollView {
                VStack(spacing: 24) {
                    header
                    if let failure { failureNote(failure) }
                    if connection.showsLocalNetworkHint { LocalNetworkHint() }
                    actions
                    Text(
                        "Open Shidou on your Mac, then Settings → Daemon to show its pairing code."
                    )
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                    demo
                }
                .padding(24)
                .frame(maxWidth: 480)
                .frame(maxWidth: .infinity, minHeight: proxy.size.height)
            }
        }
        .sheet(isPresented: $isScanning) {
            PairingScanSheet { payload in
                isScanning = false
                accept(payload)
            }
        }
        .sheet(isPresented: $isEnteringManually) {
            ManualEntrySheet { payload in
                isEnteringManually = false
                accept(payload)
            }
        }
        .alert(
            "Could not pair",
            isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })
        ) {
            Button("OK") { error = nil }
        } message: {
            Text(error ?? "")
        }
    }

    private var header: some View {
        VStack(spacing: 10) {
            Image(systemName: "antenna.radiowaves.left.and.right")
                .font(.system(size: 44))
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
            Text("Connect to your Mac")
                .font(.title2.bold())
            Text("Shidou runs on your own computer. Pair this phone with its daemon to see your sessions.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }

    private func failureNote(_ failure: ConnectionFailure) -> some View {
        Label(failure.message, systemImage: "exclamationmark.triangle.fill")
            .font(.footnote)
            .foregroundStyle(.primary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(Color.yellow.opacity(0.15), in: RoundedRectangle(cornerRadius: 10))
    }

    private var actions: some View {
        VStack(spacing: 12) {
            Button {
                isScanning = true
            } label: {
                Label("Scan pairing code", systemImage: "qrcode.viewfinder")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)

            Button("Enter address manually") { isEnteringManually = true }
                .buttonStyle(.bordered)
                .frame(maxWidth: .infinity)
        }
    }

    /// The try-before-you-install path, and the one an App Review reviewer
    /// takes. It is a real connection to a real server rather than an in-app
    /// demo mode, which is what keeps it out of the "needs prior Apple
    /// approval" branch of guideline 2.1.
    private var demo: some View {
        VStack(spacing: 6) {
            Divider().padding(.vertical, 4)
            Button("Try the demo") { connection.startDemo() }
                .buttonStyle(.bordered)
                .frame(maxWidth: .infinity)
            Text("Connects to Shidou's public demo server with a scripted session. Nothing in it runs on your computer.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }

    private func accept(_ payload: PairingPayload) {
        do {
            try connection.pair(with: payload)
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// iOS denies local-network traffic without a word when the permission is
/// off, so the hint has to name the exact Settings path rather than leave the
/// user guessing at a dead connection.
private struct LocalNetworkHint: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Local Network access may be off", systemImage: "wifi.exclamationmark")
                .font(.footnote.bold())
            Text("Shidou needs it to reach a Mac on the same Wi-Fi. Check Settings → Privacy & Security → Local Network, or connect over Tailscale instead.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            if let url = URL(string: UIApplication.openSettingsURLString) {
                Link("Open Settings", destination: url)
                    .font(.footnote)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10))
    }
}

private struct ManualEntrySheet: View {
    let onSubmit: (PairingPayload) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var address = ""
    @State private var token = ""
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("mac.local:34123", text: $address)
                        .textContentType(.URL)
                        .keyboardType(.URL)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                } header: {
                    Text("Address")
                } footer: {
                    Text("A host and port, or a full ws:// URL. A pasted pairing link works too.")
                }

                Section("Token") {
                    SecureField("Daemon token", text: $token)
                        .textContentType(.password)
                        .autocorrectionDisabled()
                }

                if let error {
                    Section {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Enter address")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Connect", action: submit)
                        .disabled(address.trimmed.isEmpty)
                }
            }
        }
    }

    private func submit() {
        // A pasted `shidou://pair` link carries everything, including the
        // daemon's other addresses — much better than the single address the
        // user would otherwise type.
        if let url = URL(string: address.trimmed), url.scheme?.lowercased() == PairingPayload.scheme {
            do {
                onSubmit(try PairingPayload(url: url))
            } catch {
                self.error = error.localizedDescription
            }
            return
        }
        guard !token.trimmed.isEmpty else {
            error = "The daemon token is required."
            return
        }
        do {
            // Manual entry knows one address and no daemon identity, so the
            // phone mints one; it only ever keys local storage.
            onSubmit(try PairingPayload(
                daemonId: UUID().uuidString,
                name: nil,
                addresses: [address.trimmed],
                token: token.trimmed
            ))
        } catch {
            self.error = error.localizedDescription
        }
    }
}

extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
