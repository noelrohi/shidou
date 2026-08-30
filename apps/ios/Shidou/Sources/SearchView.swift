import ShidouProtocol
import ShidouSession
import SwiftUI

/// The search screen: the drawer's search button covers the task with it, and
/// the iPad sidebar pushes it.
///
/// The field sits at the bottom, where the keyboard it summons already is, so
/// the thumb that opened search is the thumb that types — the layout Claude's
/// iOS search settled on. Until something is typed the screen is empty on
/// purpose: a glyph and one line saying what it will look through, centred in
/// the room that a list of everything would otherwise fill. Hits are one flat
/// newest-first list, and rows reuse `SessionRow` so a hit reads exactly like
/// the row it names; rename and delete stay on the list, which owns them.
struct SearchView: View {
    @Binding var selection: UUID?

    @Environment(DaemonConnection.self) private var connection
    @Environment(\.dismiss) private var dismiss

    @State private var query = ""
    @State private var now = Date()

    @FocusState private var fieldFocused: Bool

    private var store: SessionStore? { connection.sessions }

    private var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The hits, newest first: the sidebar's own grouping asked only for what
    /// the query matches, flattened to one list.
    private var hits: [SessionListItem] {
        guard let store, !trimmedQuery.isEmpty else { return [] }
        return SessionListPresentation.groups(
            sessions: store.sessions,
            projects: store.projects,
            grouping: .updated,
            ordering: .newest,
            query: query
        )
        .flatMap(\.items)
    }

    var body: some View {
        list
            .overlay { emptyState }
            .background(Color(.systemBackground).ignoresSafeArea())
            .floatingBottomBar { field }
            .refreshable { store?.refreshCatalog() }
            .task(id: tickKey) { await tick() }
            .onAppear { fieldFocused = true }
            .toolbar(.hidden, for: .navigationBar)
    }

    // MARK: - Field

    /// A capsule and a close button, floating at the bottom over whatever the
    /// list scrolled under it. Close leaves the screen; clearing a query is
    /// the field's own affair, inside the capsule.
    private var field: some View {
        GlassGroup(spacing: 10) {
            HStack(spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .font(.body.weight(.medium))
                        .foregroundStyle(.primary)
                        .accessibilityHidden(true)
                    TextField("Search", text: $query)
                        .textFieldStyle(.plain)
                        .font(.body)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .submitLabel(.search)
                        .focused($fieldFocused)
                        .accessibilityLabel("Search tasks")
                    if !query.isEmpty {
                        Button {
                            query = ""
                            fieldFocused = true
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.body)
                                .foregroundStyle(.tertiary)
                                .frame(width: 28, height: 28)
                                .contentShape(Circle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Clear search")
                    }
                }
                .padding(.leading, 16)
                .padding(.trailing, 10)
                .frame(height: 50)
                .glassSurface(in: Capsule(), fallback: AnyShapeStyle(.thickMaterial))
                .fallbackBorder(Capsule())

                Button(action: { dismiss() }) {
                    Image(systemName: "xmark")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.primary)
                        .frame(width: 50, height: 50)
                        .glassSurface(
                            in: Circle(),
                            interactive: true,
                            fallback: AnyShapeStyle(.thickMaterial)
                        )
                        .fallbackBorder(Circle())
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close search")
                .keyboardShortcut(.cancelAction)
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 8)
        .padding(.bottom, 10)
        .floatingBarBackdrop()
    }

    // MARK: - Hits

    private var list: some View {
        List(hits) { item in
            Button {
                selection = item.session.id
                dismiss()
            } label: {
                SessionRow(
                    item: item,
                    now: UInt64(now.timeIntervalSince1970)
                )
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            .buttonStyle(.plain)
            .listRowInsets(EdgeInsets(top: 1, leading: 12, bottom: 1, trailing: 12))
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .scrollDismissesKeyboard(.interactively)
        .environment(\.defaultMinListRowHeight, 1)
    }

    @ViewBuilder
    private var emptyState: some View {
        if let store, store.hasLoadedCatalog, hits.isEmpty {
            if trimmedQuery.isEmpty {
                prompt
            } else {
                ContentUnavailableView {
                    Label("No matches", systemImage: "magnifyingglass")
                } description: {
                    Text("No task's title, project or branch contains “\(query)”.")
                }
            }
        } else if let error = store?.catalogError {
            ContentUnavailableView {
                Label("Could not load your tasks", systemImage: "exclamationmark.triangle")
            } description: {
                Text(error)
            } actions: {
                Button("Try again") { store?.refreshCatalog() }
            }
        } else if store?.hasLoadedCatalog != true {
            ProgressView()
        }
    }

    /// The screen before a query: the glyph and one line, nothing that looks
    /// like a result.
    private var prompt: some View {
        VStack(spacing: 20) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 44, weight: .regular))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text("Search tasks, projects and branches")
                .font(.body)
                .foregroundStyle(.primary)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .allowsHitTesting(false)
    }

    // MARK: - Data

    /// The same re-timing the list uses: seconds while a hit's turn runs,
    /// otherwise the next minute, hour, or midnight.
    private var tickKey: Int {
        store?.sessions.reduce(into: 0) { $0 ^= $1.status.hashValue } ?? 0
    }

    private func tick() async {
        guard let store else { return }
        while !Task.isCancelled {
            let delay = SessionListPresentation.nextRefreshDelay(store.sessions, now: now)
            try? await Task.sleep(for: .seconds(delay))
            if Task.isCancelled { return }
            now = Date()
        }
    }
}
