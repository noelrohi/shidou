import Foundation
import Network
import ShidouClient
import ShidouProtocol
import ShidouSession
import SwiftUI
import UIKit

/// What the UI must show about the connection right now.
///
/// Three tiers, from the pairing decision: a healthy connection says nothing,
/// a connection that is coming back says it quietly without taking the screen
/// away, and only a dead end takes over.
enum ConnectionPresentation: Equatable {
    /// Connected, or nothing worth interrupting for.
    case silent
    /// Reconnecting behind a screen the user can keep reading.
    case inlineIndicator
    /// The daemon rotated its token: keep the daemon, replace the token.
    case repairScreen(String)
    /// Never paired, or a dead end retrying cannot fix.
    case connectionScreen(ConnectionFailure?)
}

/// Owns the phone's one Saved Daemon and the supervisor connecting to it.
///
/// Lifecycle lives here rather than in the views because iOS drives it: a
/// scene going background starts the Grace Window, and a network path change
/// is the single best moment to retry. Both are app-wide facts, not view
/// state.
@MainActor
@Observable
final class DaemonConnection {
    /// How long the socket may outlive backgrounding. iOS grants roughly 30
    /// seconds of execution after the scene leaves the foreground, and the
    /// notifications decision spends it keeping the connection alive so
    /// attention events can still arrive. When it runs out, `suspend()` takes
    /// the socket down cleanly and harvests replay cursors.
    static let graceWindow: Duration = .seconds(30)

    private(set) var saved: SavedDaemon?
    private(set) var phase: ConnectionPhase = .idle
    private(set) var daemonVersion: String?
    /// A connection has succeeded at least once this launch, so there is
    /// something on screen worth keeping while we reconnect.
    private(set) var hasEverConnected = false
    /// Candidate walks that ended with every address failing. Two of them on
    /// a LAN-reachable daemon that has never connected is what surfaces the
    /// Local Network hint.
    private(set) var exhaustedRounds = 0
    /// Set once per daemon, when pairing lands on a cleartext address that is
    /// neither loopback nor tailnet.
    private(set) var pendingInsecureWarning: SavedDaemon?
    /// The client-side model of whatever daemon is currently connected.
    ///
    /// It lives beside the supervisor rather than in a view because it is the
    /// supervisor's peer: one is the connection, the other is everything the
    /// connection is for. A store outlives any screen, and a screen that
    /// disappears must not take a session's projection with it.
    private(set) var sessions: SessionStore?

    private let store: SavedDaemonStore
    private let tokens: TokenStore
    private let clientId = UUID()

    private var supervisor: ConnectionSupervisor?
    /// Stops a supervisor whose token read was still in flight from landing
    /// on top of a newer one — or on a `disconnect()` that meant to end it.
    private var connectGeneration = 0
    private var pump: Task<Void, Never>?
    private var pathMonitor: NWPathMonitor?
    private var graceTimer: Task<Void, Never>?
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid

    /// The Keychain sits behind `DemoTokenStore` so the Demo Daemon's public
    /// token is answered from the constant it lives in and never written.
    init(
        store: SavedDaemonStore = SavedDaemonStore(),
        tokens: TokenStore = DemoTokenStore(wrapping: KeychainTokenStore())
    ) {
        self.store = store
        self.tokens = tokens
    }

    // MARK: - Derived state

    var presentation: ConnectionPresentation {
        guard let saved else { return .connectionScreen(nil) }
        if saved.tokenIsInvalid, saved.allowsTokenRepair {
            if case .failed(.tokenRejected(let message)) = phase { return .repairScreen(message) }
            return .repairScreen("The daemon rejected this token.")
        }
        switch phase {
        case .connected:
            return .silent
        case .failed(let failure):
            return .connectionScreen(failure)
        case .idle, .connecting, .backingOff:
            return hasEverConnected ? .inlineIndicator : .connectionScreen(nil)
        }
    }

    /// The one-time cleartext warning, shown at pairing and never again.
    var showsInsecureBadge: Bool { saved?.warnsAboutInsecureTransport ?? false }

    /// The phone is on the Demo Daemon, which the transcript says out loud
    /// for as long as it lasts — nothing on screen is running on a Mac.
    var isDemo: Bool { saved?.isDemo ?? false }

    /// iOS denies local-network traffic silently when the permission is off,
    /// so a LAN daemon that never answers looks exactly like a daemon that is
    /// not running. After a second failed walk we say so rather than let the
    /// user keep guessing.
    var showsLocalNetworkHint: Bool {
        guard let saved, saved.hasLocalNetworkCandidate else { return false }
        return !hasEverConnected && exhaustedRounds >= 2
    }

    var connectingAddress: String? {
        phase.endpoint?.candidate.host
    }

    // MARK: - Pairing

    func restore() {
        saved = store.current()
        connectIfPossible()
    }

    /// Accepts a scanned QR, a tapped `shidou://pair` link, or manual entry.
    func pair(with payload: PairingPayload) throws {
        var daemon = SavedDaemon(payload: payload)
        do {
            try tokens.setToken(payload.token, for: daemon.id)
        } catch {
            pairingLog.error(
                "keychain write failed: \(error.localizedDescription, privacy: .public)"
            )
            throw error
        }
        // Re-pairing the same daemon keeps what the phone already learned:
        // which address worked, and whether the warning has been seen.
        if let existing = store.current() {
            if existing.id == daemon.id {
                daemon.lastGoodAddress = existing.lastGoodAddress
                daemon.acknowledgedInsecureWarning = existing.acknowledgedInsecureWarning
                daemon.pairedAt = existing.pairedAt
            } else {
                // Pairing with a different Mac: the old token has no owner
                // left, so it should not outlive the daemon it belonged to.
                try? tokens.removeToken(for: existing.id)
            }
        }
        adopt(daemon)
        if daemon.warnsAboutInsecureTransport && !daemon.acknowledgedInsecureWarning {
            pendingInsecureWarning = daemon
        }
    }

    /// "Try the demo": the Demo Daemon persists exactly like a paired Mac,
    /// so everything from here — the candidate walk, last-good persistence,
    /// backoff, the Grace Window — is the path a real daemon takes. Pairing a
    /// Mac later replaces this saved daemon and the demo is gone.
    func startDemo() {
        adopt(DemoDaemon.saved())
        pendingInsecureWarning = nil
    }

    /// Installs the phone's one Saved Daemon and starts connecting to it.
    ///
    /// The list-of-one is the eviction: whatever was saved before is gone,
    /// which is how pairing a Mac ends the demo and how the demo ends a
    /// stale pairing. A token left behind by a daemon that no longer has a
    /// slot has no owner, so it goes with it.
    private func adopt(_ daemon: SavedDaemon) {
        if let existing = store.current(), existing.id != daemon.id {
            try? tokens.removeToken(for: existing.id)
        }
        store.replace(with: daemon)
        saved = daemon
        hasEverConnected = false
        exhaustedRounds = 0
        connectIfPossible()
    }

    func acknowledgeInsecureWarning() {
        pendingInsecureWarning = nil
        store.update { $0.acknowledgedInsecureWarning = true }
        saved = store.current()
    }

    /// Replaces the token on the daemon already saved, leaving its addresses
    /// alone — the re-pair screen's "edit token" path.
    func replaceToken(_ token: String) throws {
        guard let existing = saved else { return }
        let cleaned = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return }
        try tokens.setToken(cleaned, for: existing.id)
        store.update { $0.tokenIsInvalid = false }
        saved = store.current()
        connectIfPossible()
    }

    func forget() {
        disconnect()
        if let saved { try? tokens.removeToken(for: saved.id) }
        store.removeAll()
        self.saved = nil
        phase = .idle
        daemonVersion = nil
        hasEverConnected = false
        exhaustedRounds = 0
        pendingInsecureWarning = nil
    }

    // MARK: - Lifecycle

    func enterForeground() {
        cancelGraceWindow()
        guard let supervisor else {
            connectIfPossible()
            return
        }
        Task { await supervisor.retryImmediately() }
        startPathMonitor()
    }

    /// Backgrounding starts the Grace Window rather than dropping the socket:
    /// the connection has to outlive the transition for attention events to
    /// still reach the user. Suspending is what happens when it expires.
    func enterBackground() {
        guard supervisor != nil else { return }
        stopPathMonitor()
        cancelGraceWindow()
        backgroundTask = UIApplication.shared.beginBackgroundTask(
            withName: "shidou.grace-window"
        ) { [weak self] in
            // iOS is out of patience before our own timer fired. It calls
            // this on the main thread and expects the identifier back before
            // it returns — deferring that to another turn is what gets an app
            // killed by the watchdog. Dropping the socket is best-effort
            // afterwards; the connection dies with the process regardless.
            MainActor.assumeIsolated {
                guard let self else { return }
                self.graceTimer?.cancel()
                self.graceTimer = nil
                self.endBackgroundTask()
                Task { await self.supervisor?.suspend() }
            }
        }
        graceTimer = Task { [graceWindow = Self.graceWindow] in
            try? await Task.sleep(for: graceWindow)
            if Task.isCancelled { return }
            await self.suspendNow()
        }
    }

    private func suspendNow() async {
        graceTimer?.cancel()
        graceTimer = nil
        if let supervisor { await supervisor.suspend() }
        endBackgroundTask()
    }

    private func cancelGraceWindow() {
        graceTimer?.cancel()
        graceTimer = nil
        endBackgroundTask()
    }

    private func endBackgroundTask() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }

    // MARK: - Connecting

    private func connectIfPossible() {
        disconnect()
        guard let daemon = saved, !daemon.tokenIsInvalid else { return }
        connectGeneration &+= 1
        let generation = connectGeneration
        let tokens = self.tokens
        let daemonId = daemon.id
        Task { [weak self] in
            // `SecItemCopyMatching` is blocking IPC to securityd, and this
            // path runs at launch and on every foreground — not a tap the
            // user is waiting on. The UI thread does not wait for it.
            let token = await Task.detached(priority: .userInitiated) {
                tokens.token(for: daemonId)
            }.value
            guard let self, self.connectGeneration == generation else { return }
            self.startSupervisor(for: daemon, token: token)
        }
    }

    private func startSupervisor(for daemon: SavedDaemon, token: String?) {
        guard let token else {
            // The daemon is saved but its token is gone (restored backup, or
            // a Keychain the app can no longer read): the re-pair screen is
            // exactly the right recovery.
            store.update { $0.tokenIsInvalid = true }
            saved = store.current()
            return
        }
        let endpoints = daemon.endpoints(token: token)
        guard !endpoints.isEmpty else {
            phase = .failed(.invalidAddress(daemon.addresses.first?.raw ?? ""))
            return
        }
        let supervisor = ConnectionSupervisor(candidates: endpoints, clientId: clientId)
        self.supervisor = supervisor
        let sessions = SessionStore(supervisor: supervisor)
        self.sessions = sessions
        sessions.start()
        pump = Task { [weak self] in
            let stream = await supervisor.events()
            await supervisor.start()
            for await item in stream {
                guard let self else { return }
                self.handle(item)
            }
        }
        startPathMonitor()
    }

    private func handle(_ item: SupervisedEvent) {
        switch item {
        case .phase(let phase):
            let wasWalking = self.phase
            self.phase = phase
            switch phase {
            case .connected(let hello, _):
                daemonVersion = hello.daemonVersion
                hasEverConnected = true
                exhaustedRounds = 0
            case .backingOff:
                // Backoff only follows a walk in which every candidate failed.
                if case .connecting = wasWalking { exhaustedRounds += 1 }
            case .failed(.tokenRejected):
                store.update { $0.tokenIsInvalid = true }
                saved = store.current()
            case .failed, .idle, .connecting:
                break
            }
        case .selectedCandidate(let endpoint):
            store.update { daemon in
                daemon.lastGoodAddress = endpoint.candidate
            }
            saved = store.current()
        case .reconnected, .event, .taskStateChanged, .replayGap:
            // The session store subscribes to the same supervisor and owns
            // these: re-attachment, catalog invalidation, and refetching a
            // session whose replay came up short.
            break
        }
    }

    /// Drops the current supervisor synchronously, so a caller can install a
    /// replacement in the same turn without the old one's teardown landing on
    /// top of it.
    private func disconnect() {
        let outgoing = supervisor
        connectGeneration &+= 1
        pump?.cancel()
        pump = nil
        supervisor = nil
        sessions?.stop()
        sessions = nil
        stopPathMonitor()
        cancelGraceWindow()
        guard let outgoing else { return }
        Task { await outgoing.stop() }
    }

    // MARK: - Network path

    /// A path change is the cheapest possible reconnect trigger: leaving Wi-Fi
    /// for cellular is exactly when the LAN candidate dies and the tailnet one
    /// starts working.
    private func startPathMonitor() {
        guard pathMonitor == nil else { return }
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            guard path.status == .satisfied else { return }
            Task { @MainActor [weak self] in
                guard let supervisor = self?.supervisor else { return }
                await supervisor.retryImmediately()
            }
        }
        monitor.start(queue: .main)
        pathMonitor = monitor
    }

    private func stopPathMonitor() {
        pathMonitor?.cancel()
        pathMonitor = nil
    }
}
