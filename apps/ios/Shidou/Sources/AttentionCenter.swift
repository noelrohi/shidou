import ShidouProtocol
import ShidouSession
import SwiftUI
import UserNotifications

/// Where an attention event goes.
///
/// The notifications decision drew this line and this file keeps it: while the
/// app is open, a blocking prompt on a task you are not looking at becomes an
/// in-app banner; once the app is backgrounded, the same events become local
/// notifications for as long as the Grace Window keeps the socket alive. There
/// is no remote push in v1 — a user's own daemon cannot hold an APNs key — and
/// there is never an app icon badge.
@MainActor
@Observable
final class AttentionCenter: NSObject {
    /// The banner currently on screen, if any.
    private(set) var banner: Banner?
    /// A notification the user tapped, for the spine to open.
    var openSessionId: UUID?
    /// The transcript on screen. Nothing about it is ever notified: the user
    /// is already looking at it.
    var visibleSessionId: UUID?
    var isForeground = true

    @ObservationIgnored private var pump: Task<Void, Never>?
    @ObservationIgnored private weak var store: SessionStore?
    @ObservationIgnored private var bannerDismissal: Task<Void, Never>?
    @ObservationIgnored private var askedForAuthorization = false

    struct Banner: Identifiable, Equatable {
        let id = UUID()
        let sessionId: UUID
        let title: String
        let message: String
        let systemImage: String
    }

    static let bannerDuration: Duration = .seconds(6)

    override init() {
        super.init()
        UNUserNotificationCenter.current().delegate = self
    }

    /// Follows one store's attention stream. A new connection means a new
    /// store, and the old stream ends with it.
    func follow(_ store: SessionStore?) {
        guard self.store !== store else { return }
        pump?.cancel()
        banner = nil
        self.store = store
        guard let store else {
            pump = nil
            return
        }
        pump = Task { [weak self] in
            for await event in store.attentionEvents() {
                guard let self else { return }
                self.handle(event, store: store)
            }
        }
    }

    /// Asks for notification permission at the moment it starts to mean
    /// something — the first prompt the user sends — rather than at launch,
    /// where the request has nothing to explain itself with.
    func requestAuthorizationIfNeeded() {
        guard !askedForAuthorization else { return }
        askedForAuthorization = true
        Task {
            // No `.badge`: the decision says no app icon badge, so the app
            // should not hold a permission it will never use.
            _ = try? await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .sound])
        }
    }

    func dismissBanner() {
        bannerDismissal?.cancel()
        bannerDismissal = nil
        banner = nil
    }

    // MARK: - Routing

    private func handle(_ event: AttentionEvent, store: SessionStore) {
        let title = store.title(for: event.sessionId)
        if isForeground {
            // Only the blocking two, and only from a task that is not on
            // screen. Announcing what the user is watching is noise.
            guard event.isBlocking, event.sessionId != visibleSessionId else { return }
            present(Banner(
                sessionId: event.sessionId,
                title: title,
                message: message(for: event),
                systemImage: systemImage(for: event)
            ))
            return
        }
        post(event, title: title)
    }

    private func present(_ banner: Banner) {
        bannerDismissal?.cancel()
        self.banner = banner
        bannerDismissal = Task { [weak self] in
            try? await Task.sleep(for: Self.bannerDuration)
            guard !Task.isCancelled else { return }
            self?.banner = nil
        }
    }

    /// A local notification, fired from the Grace Window. All three attention
    /// events qualify here: "it's done" is exactly what a backgrounded phone
    /// is for.
    private func post(_ event: AttentionEvent, title: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = message(for: event)
        content.sound = .default
        content.userInfo = ["sessionId": event.sessionId.uuidString]
        content.threadIdentifier = event.sessionId.uuidString
        // `nil` fires immediately; the socket is still alive, so this is the
        // moment the event actually happened.
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(
                identifier: "\(event.sessionId.uuidString)-\(identifier(for: event))",
                content: content,
                trigger: nil
            )
        )
    }

    private func identifier(for event: AttentionEvent) -> String {
        switch event {
        case .turnFinished: return "turn-\(Int(Date().timeIntervalSince1970))"
        case .permission(_, let requestId, _): return requestId
        case .userInputRequested(_, let requestId, _): return requestId
        }
    }

    private func message(for event: AttentionEvent) -> String {
        switch event {
        case .turnFinished(_, let success, let summary):
            if let summary, !summary.isEmpty { return summary }
            return success
                ? String(localized: "Finished")
                : String(localized: "Stopped before finishing")
        case .permission(_, _, let title):
            return title.isEmpty ? String(localized: "Needs your permission") : title
        case .userInputRequested(_, _, let header):
            return header.isEmpty ? String(localized: "Has a question for you") : header
        }
    }

    private func systemImage(for event: AttentionEvent) -> String {
        switch event {
        case .permission: return "hand.raised.fill"
        case .userInputRequested: return "questionmark.circle.fill"
        case .turnFinished: return "checkmark.circle.fill"
        }
    }
}

extension AttentionCenter: UNUserNotificationCenterDelegate {
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let raw = response.notification.request.content.userInfo["sessionId"] as? String
        Task { @MainActor [weak self] in
            if let raw, let sessionId = UUID(uuidString: raw) {
                self?.openSessionId = sessionId
            }
            completionHandler()
        }
    }
}

/// The in-app banner. It names the task, says what it wants, and opening it is
/// the whole interaction — there is nothing to answer from here, because the
/// answer belongs next to the transcript that explains it.
struct AttentionBannerView: View {
    let banner: AttentionCenter.Banner
    let open: () -> Void
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: banner.systemImage)
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(banner.title)
                    .font(.footnote.weight(.semibold))
                    .lineLimit(1)
                Text(banner.message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 8)
            Button("Open", action: open)
                .font(.footnote)
                .buttonStyle(.bordered)
            Button(action: dismiss) {
                Image(systemName: "xmark")
                    .font(.caption)
                    .frame(width: 32, height: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .accessibilityLabel("Dismiss")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .overlay { RoundedRectangle(cornerRadius: 14).strokeBorder(.separator) }
        .shadow(radius: 8, y: 2)
        .padding(.horizontal, 12)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(verbatim: "\(banner.title): \(banner.message)"))
    }
}
