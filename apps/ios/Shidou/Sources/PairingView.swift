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
                VStack(spacing: 0) {
                    Spacer(minLength: 24)
                    header
                    Spacer(minLength: 28)
                    notes
                    actions
                    Spacer(minLength: 28)
                    demo
                }
                .padding(.horizontal, 28)
                .padding(.vertical, 24)
                .frame(maxWidth: 420)
                .frame(maxWidth: .infinity, minHeight: proxy.size.height)
            }
            .scrollBounceBehavior(.basedOnSize)
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

    /// The pairing this screen is asking for, said as a picture before it is
    /// said in words: the two machines, on the tinted tile the system uses for
    /// a first-run glyph.
    private var header: some View {
        VStack(spacing: 14) {
            Image(systemName: "macbook.and.iphone")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(.tint)
                .frame(width: 76, height: 76)
                .background(
                    .tint.opacity(0.12),
                    in: RoundedRectangle(cornerRadius: 20, style: .continuous)
                )
                .accessibilityHidden(true)
            VStack(spacing: 8) {
                Text("Connect to your Mac")
                    .font(.title2.bold())
                    .multilineTextAlignment(.center)
                Text("Shidou runs on your own computer. Pair this phone with its daemon to see your sessions.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
    }

    /// Everything conditional, in one stack that costs no space when nothing
    /// has gone wrong — the screen a first-time user sees is the header and
    /// the two buttons, and nothing else.
    @ViewBuilder
    private var notes: some View {
        VStack(spacing: 12) {
            if let failure { failureNote(failure) }
            if connection.showsLocalNetworkHint { LocalNetworkHint() }
        }
        .padding(.bottom, failure == nil && !connection.showsLocalNetworkHint ? 0 : 20)
    }

    private func failureNote(_ failure: ConnectionFailure) -> some View {
        NoteCard(systemImage: "exclamationmark.triangle.fill", tint: .orange) {
            Text(failure.message)
                .font(.footnote)
        }
    }

    private var actions: some View {
        VStack(spacing: 14) {
            Button {
                isScanning = true
            } label: {
                Label("Scan pairing code", systemImage: "qrcode.viewfinder")
                    .fontWeight(.semibold)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.capsule)
            .controlSize(.large)

            // Plain, not bordered: two filled buttons stacked read as a pair of
            // equals, and scanning is the path almost everyone takes.
            Button("Enter address manually") { isEnteringManually = true }
                .font(.subheadline.weight(.medium))

            Text("Open Shidou on your Mac, then Settings → Daemon to show its pairing code.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.top, 2)
        }
    }

    /// The try-before-you-install path, and the one an App Review reviewer
    /// takes. It is a real connection to a real server rather than an in-app
    /// demo mode, which is what keeps it out of the "needs prior Apple
    /// approval" branch of guideline 2.1.
    ///
    /// It sits at the foot of the screen, quiet: an aside, not a third way to
    /// connect competing with the two that reach the user's own Mac.
    private var demo: some View {
        VStack(spacing: 6) {
            Button("Try the demo") { connection.startDemo() }
                .font(.subheadline.weight(.medium))
            Text("Connects to Shidou's public demo server with a scripted session. Nothing in it runs on your computer.")
                .font(.caption)
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
        NoteCard(systemImage: "wifi.exclamationmark", tint: .accentColor) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Local Network access may be off")
                    .font(.footnote.weight(.semibold))
                Text("Shidou needs it to reach a Mac on the same Wi-Fi. Check Settings → Privacy & Security → Local Network, or connect over Tailscale instead.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    Link("Open Settings", destination: url)
                        .font(.footnote.weight(.medium))
                }
            }
        }
    }
}

/// One shape for everything this screen has to say beyond its two buttons.
/// A single card treatment is what keeps a warning and a hint from reading as
/// two unrelated pieces of chrome stacked on the same screen.
private struct NoteCard<Content: View>: View {
    let systemImage: String
    let tint: Color
    @ViewBuilder var content: Content

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: systemImage)
                .font(.footnote)
                .foregroundStyle(tint)
                .accessibilityHidden(true)
            content
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(12)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

private struct ManualEntrySheet: View {
    let onSubmit: (PairingPayload) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var address = ""
    @State private var token = ""
    @State private var error: String?
    @FocusState private var focusedField: Field?

    private enum Field: Hashable { case address, token }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(
                        text: $address,
                        prompt: Text(verbatim: "mac.local:34123")  // an example, not a sentence
                    ) {
                        EmptyView()
                    }
                        .textContentType(.URL)
                        .keyboardType(.URL)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .focused($focusedField, equals: .address)
                        .submitLabel(.next)
                        .onSubmit { focusedField = .token }
                } header: {
                    Text("Address")
                } footer: {
                    Text("A host and port, or a full ws:// URL. A pasted pairing link works too.")
                }

                Section("Token") {
                    SecureField("Daemon token", text: $token)
                        .textContentType(.password)
                        .autocorrectionDisabled()
                        .focused($focusedField, equals: .token)
                        .submitLabel(.go)
                        .onSubmit { submit() }
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
