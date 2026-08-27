import ShidouClient
import SwiftUI

@main
struct ShidouApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @State private var connection = DaemonConnection()
    @State private var openURLError: String?

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(connection)
                .task { connection.restore() }
                .onOpenURL { url in
                    // Registering `shidou://` is what makes both the QR and a
                    // tapped pairing link work; the phone treats them the same.
                    do {
                        try connection.pair(with: try PairingPayload(url: url))
                    } catch {
                        openURLError = error.localizedDescription
                    }
                }
                .alert(
                    "Could not pair",
                    isPresented: Binding(
                        get: { openURLError != nil },
                        set: { if !$0 { openURLError = nil } }
                    )
                ) {
                    Button("OK") { openURLError = nil }
                } message: {
                    Text(openURLError ?? "")
                }
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                connection.enterForeground()
            case .background:
                connection.enterBackground()
            case .inactive:
                // A transient state: the app is mid-transition, or a system
                // sheet is up. Dropping the socket here would churn.
                break
            @unknown default:
                break
            }
        }
    }
}
