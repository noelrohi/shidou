import SwiftUI

/// The loading → error + retry → empty ladder every surface overlay shares,
/// with its one localized string ("Try again") written once.
extension View {
    @ViewBuilder
    func surfaceState(
        isEmpty: Bool,
        isLoading: Bool,
        error: String?,
        hasLoaded: Bool = true,
        retry: @escaping () -> Void,
        failureTitle: LocalizedStringKey,
        failureIcon: String,
        @ViewBuilder empty: () -> some View
    ) -> some View {
        overlay {
            if isEmpty {
                if isLoading {
                    ProgressView()
                } else if let error {
                    ContentUnavailableView {
                        Label(failureTitle, systemImage: failureIcon)
                    } description: {
                        Text(error)
                    } actions: {
                        Button("Try again") { retry() }
                    }
                } else if hasLoaded {
                    empty()
                }
            }
        }
    }
}
