import ShidouClient
import SwiftUI

/// The blocking screen for a rejected token.
///
/// Rotating the token on the Mac invalidates the phone's copy, and no amount
/// of retrying fixes it — so the app stops retrying and asks for the new one.
/// The Saved Daemon's addresses survive: only the token is wrong.
struct RepairView: View {
    @Environment(DaemonConnection.self) private var connection

    let message: String
    /// Called once a new code has been accepted. The root presentation has
    /// nothing to do — it swaps itself out when the connection recovers — but
    /// a sheet has to close, or the user is left staring at the screen they
    /// just finished with.
    var onPaired: () -> Void = {}

    @State private var isScanning = false
    @State private var token = ""
    @State private var error: String?
    @FocusState private var tokenFocused: Bool

    var body: some View {
        GeometryReader { proxy in
            ScrollView {
                VStack(spacing: 20) {
                    Image(systemName: "key.slash")
                        .font(.system(size: 40))
                        .foregroundStyle(.orange)
                        .accessibilityHidden(true)
                    Text("This Mac needs pairing again")
                        .font(.title2.bold())
                        .multilineTextAlignment(.center)
                    Text(message)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    if let name = connection.saved?.name {
                        Text(name)
                            .font(.footnote.monospaced())
                            .foregroundStyle(.tertiary)
                    }

                    Button {
                        isScanning = true
                    } label: {
                        Label("Scan the new code", systemImage: "qrcode.viewfinder")
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                    }
                    .buttonStyle(.borderedProminent)

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Or paste the new token")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        HStack {
                            SecureField("Daemon token", text: $token)
                                .textFieldStyle(.roundedBorder)
                                .autocorrectionDisabled()
                                .focused($tokenFocused)
                            Button("Save") { save() }
                                .buttonStyle(.bordered)
                                .disabled(token.trimmed.isEmpty)
                        }
                    }

                    if let error {
                        Text(error)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }

                    Button("Forget this Mac", role: .destructive) { connection.forget() }
                        .font(.footnote)
                        .padding(.top, 8)
                }
                .padding(24)
                .frame(maxWidth: 480)
                .frame(maxWidth: .infinity, minHeight: proxy.size.height)
            }
        }
        .sheet(isPresented: $isScanning) {
            PairingScanSheet { payload in
                isScanning = false
                do {
                    try connection.pair(with: payload)
                    onPaired()
                } catch {
                    self.error = error.localizedDescription
                }
            }
        }
    }

    private func save() {
        do {
            try connection.replaceToken(token)
            token = ""
            error = nil
            onPaired()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
