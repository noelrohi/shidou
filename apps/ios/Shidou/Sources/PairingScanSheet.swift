import ShidouClient
import SwiftUI
import UIKit

/// The camera sheet both pairing screens present.
///
/// The first-run connection screen and the re-pair screen ask the camera for
/// exactly the same thing and differ only in what they do with the payload,
/// so the chrome, the guidance, and every way scanning can fail live here
/// once. Failures stay inside the sheet rather than dismissing it: the user
/// is holding a phone up to a screen, and taking the viewfinder away to show
/// an alert costs them the aim they just found.
struct PairingScanSheet: View {
    let onScan: (PairingPayload) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var problem: Problem?

    private enum Problem: Equatable {
        case notAPairingCode
        case permissionDenied
        case cameraUnavailable

        var message: String {
            switch self {
            case .notAPairingCode:
                return "That QR code is not a Shidou pairing code."
            case .permissionDenied:
                return "Camera access is off. Turn it on in Settings, or close this and enter the address manually."
            case .cameraUnavailable:
                return "This device has no camera available. Close this and enter the address manually."
            }
        }

        /// Only a denied permission has somewhere for the user to go.
        var offersSettings: Bool { self == .permissionDenied }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                QRScannerView { value in
                    guard let url = URL(string: value),
                          let payload = try? PairingPayload(url: url)
                    else {
                        problem = .notAPairingCode
                        return
                    }
                    onScan(payload)
                } onFailure: { failure in
                    switch failure {
                    case .permissionDenied: problem = .permissionDenied
                    case .cameraUnavailable: problem = .cameraUnavailable
                    }
                }
                .ignoresSafeArea()

                VStack {
                    Spacer()
                    guidance
                        .font(.footnote)
                        .multilineTextAlignment(.center)
                        .padding(12)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
                        .padding(24)
                }
            }
            .navigationTitle("Scan code")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }

    @ViewBuilder
    private var guidance: some View {
        if let problem {
            VStack(spacing: 8) {
                Text(problem.message)
                if problem.offersSettings, let url = URL(string: UIApplication.openSettingsURLString) {
                    Link("Open Settings", destination: url)
                }
            }
        } else {
            Text("Point the camera at the code in Settings → Daemon on your Mac.")
        }
    }
}
