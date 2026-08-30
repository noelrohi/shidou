import ShidouProtocol
import ShidouSession
import SwiftUI

/// The screen the sidebar's search row routes to.
///
/// Search is a destination, not a drawer row: the field takes focus on
/// arrival, the hits are one flat newest-first list instead of sections that
/// shrink as you type, and an empty state has the room to say what a query
/// missed. Rows reuse `SessionRow`, so a hit reads exactly like the row it
/// names; rename and delete stay on the list, which owns them.
struct SearchView: View {
    @Binding var selection: UUID?

    @Environment(DaemonConnection.self) private var connection
    @Environment(\.dismiss) private var dismiss

    @State private var query = ""
    @State private var now = Date()

    @FocusState private var fieldFocused: Bool

    private var store: SessionStore? { connection.sessions }

    /// The hits, newest first: the sidebar's own grouping asked only for what
    /// the query matches, flattened to one list.
    private var hits: [SessionListItem] {
        guard let store else { return [] }
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
        VStack(spacing: 0) {
            field
            list
                .overlay { emptyState }
        }
        .refreshable { store?.refreshCatalog() }
        .task(id: tickKey) { await tick() }
        .onAppear { fieldFocused = true }
        .toolbar(.hidden, for: .navigationBar)
    }

    // MARK: - Field

    /// The sidebar row's field, standing on its own screen now, with a Cancel
    /// that leaves by the same route the row came in.
    private var field: some View {
        HStack(spacing: 10) {
            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                TextField("Search tasks", text: $query)
                    .textFieldStyle(.plain)
                    .font(.subheadline)
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
                            .font(.footnote)
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear search")
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                .quaternary.opacity(0.5),
                in: RoundedRectangle(cornerRadius: 10, style: .continuous)
            )

            Button("Cancel") { dismiss() }
                .font(.subheadline)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

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
        .scrollDismissesKeyboard(.interactively)
        .environment(\.defaultMinListRowHeight, 1)
    }

    @ViewBuilder
    private var emptyState: some View {
        if let store, store.hasLoadedCatalog, hits.isEmpty {
            if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                ContentUnavailableView {
                    Label("Search your tasks", systemImage: "magnifyingglass")
                } description: {
                    Text("Find a task by its title, project or branch.")
                }
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
