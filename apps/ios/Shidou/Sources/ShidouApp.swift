import ShidouClient
import SwiftUI

@main
struct ShidouApp: App {
    /// The marketing version, for the About page and the settings footer.
    static var versionLabel: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
    }

    @Environment(\.scenePhase) private var scenePhase
    /// The app's own light/dark choice. The daemon strips `theme` out of its
    /// settings file precisely because it belongs to whichever client is
    /// reading, so this is stored on the phone.
    @AppStorage(ThemeChoice.storageKey) private var theme = ThemeChoice.system.rawValue
    @State private var connection = DaemonConnection()
    @State private var attention = AttentionCenter()
    @State private var openURLError: String?

    var body: some Scene {
        WindowGroup {
            RootView()
                .preferredColorScheme(ThemeChoice(rawValue: theme)?.colorScheme)
                .environment(connection)
                .environment(attention)
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
                attention.isForeground = true
                connection.enterForeground()
            case .background:
                // The Grace Window starts here, and everything it catches
                // becomes a local notification rather than a banner nobody is
                // looking at.
                attention.isForeground = false
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
