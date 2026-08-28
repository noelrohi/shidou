import ShidouProtocol
import ShidouSession
import SwiftUI

/// The skills catalog: what each agent can be asked to do, and which of them
/// are turned on.
///
/// Enabling and trashing both act on every directory a skill occupies, because
/// one skill can be installed for several agents and turning it off for only
/// one of them is not what the row says.
struct SkillsSettingsView: View {
    @Environment(DaemonConnection.self) private var connection

    @State private var catalog: SkillsCatalog?
    @State private var isLoading = false
    @State private var error: String?
    @State private var query = ""
    @State private var pendingTrash: SkillEntry?

    private var store: SessionStore? { connection.sessions }

    private var visible: [SkillEntry] {
        let skills = catalog?.skills ?? []
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return skills }
        return skills.filter {
            $0.name.lowercased().contains(trimmed)
                || $0.description.lowercased().contains(trimmed)
        }
    }

    var body: some View {
        List {
            ForEach(SkillScope.allScopes, id: \.self) { scope in
                let scoped = visible.filter { $0.scope == scope }
                if !scoped.isEmpty {
                    Section {
                        ForEach(scoped) { skill in
                            NavigationLink {
                                SkillDetailView(skill: skill, setEnabled: { setEnabled($0, on: skill) })
                            } label: {
                                SkillRow(skill: skill, setEnabled: { setEnabled($0, on: skill) })
                            }
                            .swipeActions(edge: .trailing) {
                                Button("Delete", role: .destructive) { pendingTrash = skill }
                            }
                        }
                    } header: {
                        Text(scope.sectionTitle)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .searchable(text: $query, prompt: Text("Search skills"))
        .surfaceState(
            isEmpty: visible.isEmpty,
            isLoading: isLoading,
            error: error,
            hasLoaded: catalog != nil,
            retry: { Task { await load() } },
            failureTitle: "Could not read the skills",
            failureIcon: "wand.and.stars"
        ) {
            if !query.isEmpty {
                ContentUnavailableView.search(text: query)
            } else {
                ContentUnavailableView(
                    "No skills", systemImage: "wand.and.stars",
                    description: Text("Skills you install on the Mac show up here."))
            }
        }
        .navigationTitle("Skills")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await load() }
        .task { await load() }
        .confirmationDialog(
            pendingTrash.map { Text("Delete \($0.name)?") } ?? Text("Delete this skill?"),
            isPresented: Binding(
                get: { pendingTrash != nil }, set: { if !$0 { pendingTrash = nil } }),
            titleVisibility: .visible
        ) {
            Button("Move to Trash", role: .destructive) {
                if let skill = pendingTrash { trash(skill) }
                pendingTrash = nil
            }
            Button("Cancel", role: .cancel) { pendingTrash = nil }
        } message: {
            Text("The skill's folder moves to the Trash on your Mac. Nothing is deleted outright.")
        }
    }

    private func load() async {
        guard let store else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            catalog = try await store.loadSkills()
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func setEnabled(_ enabled: Bool, on skill: SkillEntry) {
        guard let store else { return }
        // Optimistic: the row is a switch, and a switch that waits for a round
        // trip reads as broken.
        updateLocally(skill.id) { $0.enabled = enabled }
        Task {
            do {
                try await store.setSkillsEnabled(dirs: skill.dirs, enabled: enabled)
                error = nil
            } catch {
                self.error = error.localizedDescription
                updateLocally(skill.id) { $0.enabled = !enabled }
            }
        }
    }

    private func trash(_ skill: SkillEntry) {
        guard let store else { return }
        Task {
            do {
                try await store.trashSkills(dirs: skill.dirs)
                error = nil
                await load()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    private func updateLocally(_ id: UInt64, _ change: (inout SkillEntry) -> Void) {
        guard var catalog else { return }
        guard let index = catalog.skills.firstIndex(where: { $0.id == id }) else { return }
        change(&catalog.skills[index])
        self.catalog = catalog
    }
}

extension SkillScope {
    /// Project skills lead: they are the ones a task in front of you is
    /// actually going to reach for.
    static var allScopes: [SkillScope] { [.project, .user, .unknown] }

    /// A scope this build does not recognise is its own section. Filing it
    /// under "Personal" would say where the skill lives, which is exactly what
    /// an unknown scope does not tell us.
    var sectionTitle: LocalizedStringKey {
        switch self {
        case .project: return "Project"
        case .user: return "Personal"
        case .unknown: return "Other"
        }
    }
}

private struct SkillRow: View {
    let skill: SkillEntry
    let setEnabled: (Bool) -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: skill.name)
                    .font(.body)
                    .foregroundStyle(skill.enabled ? .primary : .secondary)
                Text(verbatim: skill.description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                if let project = skill.project {
                    Text(verbatim: project)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer(minLength: 8)
            Toggle(isOn: Binding(get: { skill.enabled }, set: setEnabled)) {
                // The row is the label; an empty string literal would still
                // enter the string catalog.
                EmptyView()
            }
                .labelsHidden()
                .accessibilityLabel("Enable \(skill.name)")
        }
        .frame(minHeight: 44)
    }
}

private struct SkillDetailView: View {
    let skill: SkillEntry
    let setEnabled: (Bool) -> Void

    var body: some View {
        List {
            Section {
                Toggle("Enabled", isOn: Binding(get: { skill.enabled }, set: setEnabled))
                if let tools = skill.allowedTools, !tools.isEmpty {
                    LabeledContent("Allowed tools", value: tools)
                }
                LabeledContent("Scope") {
                    Text(skill.scope.sectionTitle)
                }
                if skill.supportingFiles > 0 {
                    LabeledContent("Supporting files", value: "\(skill.supportingFiles)")
                }
                LabeledContent("Size", value: sizeLabel)
            } header: {
                Text(verbatim: skill.description)
                    .font(.footnote)
                    .textCase(nil)
                    .foregroundStyle(.secondary)
            }

            Section("Installed for") {
                ForEach(skill.installs) { install in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(install.source.providerName ?? String(localized: "Shared"))
                        Text(verbatim: install.dir)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.head)
                    }
                    .accessibilityElement(children: .combine)
                }
            }

            if !skill.body.isEmpty {
                Section {
                    Text(verbatim: skill.body)
                        .font(.system(.footnote, design: .monospaced))
                        .textSelection(.enabled)
                } header: {
                    Text(verbatim: "SKILL.md")
                }
            }
        }
        .navigationTitle(skill.name)
        .navigationBarTitleDisplayMode(.inline)
    }

    private var sizeLabel: String {
        ByteCountFormatter.string(fromByteCount: Int64(skill.totalBytes), countStyle: .file)
    }
}
