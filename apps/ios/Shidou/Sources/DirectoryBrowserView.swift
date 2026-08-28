import ShidouProtocol
import ShidouSession
import SwiftUI

/// Browsing the daemon host's filesystem from the phone.
///
/// Both things the composer needs from the daemon's disk come through here:
/// adding a project, and attaching a file that already lives on the host. The
/// daemon answers one directory at a time, so this is a list that walks rather
/// than a tree that expands — which is also the right shape for a thumb.
struct DirectoryBrowserView: View {
    enum Mode {
        /// Choose a directory and add it as a project.
        case project
        /// Choose a file or folder to attach to the prompt.
        case attachment
    }

    let mode: Mode
    let store: SessionStore
    /// Where to start. A project browse starts at the daemon's home; an
    /// attachment browse starts in the task's own workspace.
    let root: String?
    let select: (String) async -> Bool

    @Environment(\.dismiss) private var dismiss
    @State private var path: String?
    @State private var directory: DaemonDirectory?
    @State private var loadError: String?
    @State private var filter = ""
    @State private var busy = false
    @State private var started = false

    init(
        mode: Mode,
        store: SessionStore,
        root: String? = nil,
        select: @escaping (String) async -> Bool
    ) {
        self.mode = mode
        self.store = store
        self.root = root
        self.select = select
        self._path = State(initialValue: root)
    }

    private var entries: [WorkingTreeEntry] {
        let query = filter.trimmingCharacters(in: .whitespaces).lowercased()
        let all = directory?.entries ?? []
        guard !query.isEmpty else { return all }
        return all.filter { $0.name.lowercased().contains(query) }
    }

    var body: some View {
        NavigationStack {
            List {
                if let loadError {
                    Section {
                        Text(loadError).font(.footnote).foregroundStyle(.secondary)
                        Button("Try again") { Task { await load(path) } }
                    }
                }
                if let parent = directory?.parent {
                    Button {
                        Task { await load(parent) }
                    } label: {
                        Label(name(of: parent), systemImage: "arrow.up.left")
                    }
                    .accessibilityLabel("Go up to \(name(of: parent))")
                }
                ForEach(entries) { entry in
                    row(entry)
                }
                if directory != nil && entries.isEmpty {
                    Text("This folder is empty").foregroundStyle(.secondary)
                }
            }
            .searchable(text: $filter, prompt: Text("Filter"))
            .navigationTitle(directory.map { name(of: $0.path) } ?? String(localized: "Browse"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if mode == .project {
                        // Adding is an explicit action, never a side effect of
                        // having opened a folder.
                        Button("Add") { Task { await choose(directory?.path) } }
                            .disabled(directory == nil || busy)
                    }
                }
                ToolbarItem(placement: .bottomBar) {
                    if let home = directory?.home {
                        Button {
                            Task { await load(home) }
                        } label: {
                            Label("Home", systemImage: "house")
                        }
                    }
                }
            }
            .overlay {
                if directory == nil && loadError == nil { ProgressView() }
            }
        }
        .presentationDetents([.large])
        .task {
            guard !started else { return }
            started = true
            await load(path)
        }
    }

    @ViewBuilder
    private func row(_ entry: WorkingTreeEntry) -> some View {
        if entry.isDir {
            HStack(spacing: 0) {
                Button {
                    Task { await load(entry.absolutePath) }
                } label: {
                    Label(entry.name, systemImage: "folder")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if mode == .attachment {
                    Button {
                        Task { await choose(entry.absolutePath) }
                    } label: {
                        Image(systemName: "paperclip")
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Attach \(entry.name)")
                }
            }
        } else {
            Button {
                guard mode == .attachment else { return }
                Task { await choose(entry.absolutePath) }
            } label: {
                Label(entry.name, systemImage: "doc")
                    .foregroundStyle(mode == .attachment ? .primary : .secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(mode != .attachment)
        }
    }

    private func load(_ next: String?) async {
        path = next
        loadError = nil
        do {
            directory = try await store.browseDirectory(path: next)
            filter = ""
        } catch {
            loadError = error.localizedDescription
        }
    }

    private func choose(_ target: String?) async {
        guard let target, !busy else { return }
        busy = true
        defer { busy = false }
        if await select(target) { dismiss() }
    }

    private func name(of path: String) -> String {
        let trimmed = path.hasSuffix("/") && path.count > 1 ? String(path.dropLast()) : path
        return trimmed.split(separator: "/").last.map(String.init) ?? trimmed
    }
}
