import ShidouProtocol
import ShidouSession
import SwiftUI

// The composer's two control rows, ported in structure from the web
// composer's chip strip and workspace strip — and translated into the
// platform's own idiom: each picker is a detented sheet rather than a popover,
// and every chip is a real button with a real hit region rather than an 11pt
// label. The mockup's density is not a specification; legibility is.

/// A control-row chip. It scales with Dynamic Type and keeps a full-height hit
/// region, so the row grows rather than the target shrinking.
struct ControlChip<Label: View>: View {
    let systemImage: String
    let tint: Color?
    /// Drops the written label and keeps the glyph. Reserved for the two
    /// controls whose state a single symbol says completely — access and
    /// build-versus-plan — so the strip spends its width on the ones a symbol
    /// cannot, like which model is selected. Call sites still carry the
    /// `accessibilityLabel`, which is the label that has to survive.
    let iconOnly: Bool
    let action: () -> Void
    @ViewBuilder let label: () -> Label

    @Environment(\.isEnabled) private var isEnabled
    /// The glyph column grows with the text it stands in for, so an icon-only
    /// chip stays the same height as its neighbours at every type size.
    @ScaledMetric(relativeTo: .footnote) private var glyphWidth: CGFloat = 17

    init(
        systemImage: String,
        tint: Color? = nil,
        iconOnly: Bool = false,
        action: @escaping () -> Void,
        @ViewBuilder label: @escaping () -> Label
    ) {
        self.systemImage = systemImage
        self.tint = tint
        self.iconOnly = iconOnly
        self.action = action
        self.label = label
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: systemImage)
                    .font(iconOnly ? .footnote : .caption2)
                    .foregroundStyle(tint ?? .secondary)
                    .frame(minWidth: iconOnly ? glyphWidth : nil)
                    .accessibilityHidden(true)
                if !iconOnly {
                    label()
                        .font(.footnote)
                        .foregroundStyle(tint ?? .primary)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .glassSurface(
                in: Capsule(),
                interactive: true,
                fallback: AnyShapeStyle(.quaternary.opacity(0.5))
            )
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .opacity(isEnabled ? 1 : 0.45)
    }
}

/// A sheet that presents a list of choices. Every picker in the composer is
/// one of these, so they all size, dismiss and read the same way.
struct PickerSheet<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List { content() }
                .navigationTitle(title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                    }
                }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
}

/// One selectable row. The checkmark is the state; colour never carries it.
struct PickerRow: View {
    let title: String
    var subtitle: String?
    var suffix: String?
    var systemImage: String?
    var selected: Bool
    var disabled: Bool = false
    var disabledReason: String?
    let action: () -> Void

    var body: some View {
        // A choice reads as content, not as a link: the row keeps ordinary
        // label colours and lets the checkmark carry the selection, which is
        // how every other list of choices on the platform behaves.
        Button(action: action) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                }
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(title).foregroundStyle(.primary)
                        if let suffix {
                            Text(suffix)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    if let subtitle, !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if disabled, let disabledReason {
                        Text(disabledReason)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 8)
                if selected {
                    Image(systemName: "checkmark")
                        .foregroundStyle(.tint)
                        .accessibilityHidden(true)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }
}

// MARK: - Labels ported from the web client's option vocabulary

enum ModelOptionLabel {
    /// Port of `MODEL_OPTION_KEYS`: the daemon reports provider-native ids,
    /// and these are the words Shidou uses for the ones it recognizes.
    static func label(id: String, fallback: String) -> String {
        switch id {
        case "none": return String(localized: "None")
        case "minimal": return String(localized: "Minimal")
        case "low": return String(localized: "Low")
        case "medium": return String(localized: "Medium")
        case "high": return String(localized: "High")
        case "xhigh", "extraHigh", "extra_high": return String(localized: "Extra High")
        case "max": return String(localized: "Max")
        case "200k": return String(localized: "200K")
        case "1m": return String(localized: "1M")
        case "ultra": return String(localized: "Ultra")
        case "ultracode": return String(localized: "Ultracode")
        case "auto": return String(localized: "Auto")
        case "fast": return String(localized: "Fast")
        default: return fallback
        }
    }
}

/// The access tiers, in the order the web composer lists them. `plan` is not
/// here: it is the interaction mode's business, not the access tier's.
struct AccessMode: Identifiable {
    let id: RuntimeMode
    let title: String
    let detail: String
    let systemImage: String

    static let all: [AccessMode] = [
        AccessMode(
            id: .ask,
            title: String(localized: "Supervised"),
            detail: String(localized: "Ask before commands and file changes"),
            systemImage: "lock"
        ),
        AccessMode(
            id: .autoAcceptEdits,
            title: String(localized: "Auto-accept edits"),
            detail: String(localized: "Auto-approve edits, ask before other actions"),
            systemImage: "pencil"
        ),
        AccessMode(
            id: .auto,
            title: String(localized: "Auto"),
            detail: String(
                localized: "An AI reviewer approves routine actions; risky ones still ask"),
            systemImage: "sparkles"
        ),
        AccessMode(
            id: .fullAccess,
            title: String(localized: "Full access"),
            detail: String(localized: "Allow commands and edits without prompts"),
            systemImage: "lock.open"
        ),
    ]

    /// A task in Plan mode still has an access tier underneath; the web shows
    /// `ask` for it, and so does this.
    static func selected(for mode: RuntimeMode) -> AccessMode {
        all.first { $0.id == (mode == .plan ? .ask : mode) } ?? all[3]
    }
}

enum AgentPresetCopy {
    static func label(_ preset: ProviderAgentPreset) -> String {
        switch preset.id {
        case "standard": return String(localized: "Standard mode")
        case "code": return String(localized: "Code mode")
        case "minimal": return String(localized: "Minimal mode")
        case "creator": return String(localized: "Creator mode")
        default: return preset.name
        }
    }

    static func description(_ preset: ProviderAgentPreset) -> String {
        switch preset.id {
        case "standard":
            return String(
                localized:
                    "Full coding agent with file editing, shell, file and web search, skills, planning, goals, subagents, and workflows."
            )
        case "code":
            return String(
                localized:
                    "All Standard mode capabilities, with tools exposed through the Code Mode SDK so the model can combine multi-step operations in one TypeScript program."
            )
        case "minimal":
            return String(
                localized: "Two-tool coding agent with persistent bash and str_replace_editor.")
        case "creator":
            return String(
                localized:
                    "Built for creating custom agent presets, with all Standard mode capabilities plus runtime inspection, plugin experiments, and preset-authoring guidance."
            )
        default:
            return preset.description ?? String(localized: "No description.")
        }
    }
}

// MARK: - Model picker

/// Models across every provider the daemon can run, with a Favorites tab.
///
/// The web arranges providers as a rail of icons; a phone has no room for one,
/// so the same choice is a segmented scope above the list — same information,
/// same reachability, one thumb.
struct ModelPickerSheet: View {
    let session: AgentSession
    let store: SessionStore
    @Binding var preferences: ComposerPreferences
    let onChoose: (ProviderKind, ProviderModel) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var scope: Scope

    private enum Scope: Hashable {
        case favorites
        case provider(ProviderKind)
    }

    init(
        session: AgentSession,
        store: SessionStore,
        preferences: Binding<ComposerPreferences>,
        onChoose: @escaping (ProviderKind, ProviderModel) -> Void
    ) {
        self.session = session
        self.store = store
        self._preferences = preferences
        self.onChoose = onChoose
        self._scope = State(initialValue: .provider(session.provider))
    }

    /// A task with a transcript cannot change provider: its conversation lives
    /// in that provider's own session format.
    private var lockedProvider: ProviderKind? {
        session.messages.isEmpty ? nil : session.provider
    }

    private var usableProviders: [ProviderKind] {
        ProviderKind.selectable.filter { provider in
            if let lockedProvider { return provider == lockedProvider }
            if provider == session.provider { return true }
            if store.settings?.disabledProviders.contains(provider) == true { return false }
            return store.probes[provider]?.installed == true
        }
    }

    private struct Row: Identifiable {
        let provider: ProviderKind
        let model: ProviderModel
        var id: String { "\(provider.rawValue)-\(model.id)" }
    }

    private var rows: [Row] {
        let normalized = query.trimmingCharacters(in: .whitespaces).lowercased()
        let providers: [ProviderKind]
        if normalized.isEmpty {
            switch scope {
            case .favorites: providers = usableProviders
            case .provider(let provider): providers = [provider]
            }
        } else {
            providers = usableProviders
        }
        return providers.flatMap { provider in
            (store.probes[provider]?.models ?? []).filter { model in
                if normalized.isEmpty, case .favorites = scope {
                    return preferences.isFavorite(provider: provider, model: model.id)
                }
                guard !normalized.isEmpty else { return true }
                return "\(model.name) \(model.id) \(model.subProvider ?? "") \(provider.displayName)"
                    .lowercased()
                    .contains(normalized)
            }
            .map { Row(provider: provider, model: $0) }
        }
    }

    var body: some View {
        NavigationStack {
            List {
                if query.trimmingCharacters(in: .whitespaces).isEmpty {
                    Picker("Provider", selection: $scope) {
                        Text("Favorites").tag(Scope.favorites)
                        ForEach(usableProviders, id: \.self) { provider in
                            Text(provider.displayName).tag(Scope.provider(provider))
                        }
                    }
                    .pickerStyle(.menu)
                }
                if rows.isEmpty {
                    Text(emptyMessage)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                ForEach(rows) { row in
                    modelRow(row)
                }
            }
            .searchable(text: $query, prompt: Text("Search models"))
            .navigationTitle("Model")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .task { store.refreshAllProbes() }
    }

    private var emptyMessage: String {
        if !query.trimmingCharacters(in: .whitespaces).isEmpty {
            return String(localized: "No models found")
        }
        if case .favorites = scope {
            return String(localized: "Star a model to keep it here")
        }
        return String(localized: "No models reported by this provider")
    }

    private func modelRow(_ row: Row) -> some View {
        let selected = row.provider == session.provider
            && row.model.id == (session.model ?? defaultModelId)
        let favorite = preferences.isFavorite(provider: row.provider, model: row.model.id)
        return HStack(spacing: 12) {
            Button {
                onChoose(row.provider, row.model)
                dismiss()
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.model.name)
                    Text(row.model.subProvider ?? row.provider.displayName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if selected {
                Image(systemName: "checkmark")
                    .foregroundStyle(.tint)
                    .accessibilityHidden(true)
            }
            Button {
                preferences.toggleFavorite(provider: row.provider, model: row.model.id)
            } label: {
                Image(systemName: favorite ? "star.fill" : "star")
                    .foregroundStyle(favorite ? AnyShapeStyle(.yellow) : AnyShapeStyle(.tertiary))
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(favorite ? "Remove from favorites" : "Add to favorites")
        }
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }

    private var defaultModelId: String? {
        let models = store.probes[session.provider]?.models ?? []
        return (models.first { $0.isDefault } ?? models.first)?.id
    }
}

// MARK: - Traits, presets, access

/// A single trait change. The three are independent choices, so the sheet
/// reports which one was made rather than handing back a whole session.
enum ComposerTraitChange {
    case reasoningEffort(String)
    case serviceTier(String)
    case contextWindow(String)
}

/// Reasoning effort, service tier and context window: the traits the selected
/// model itself reports. A model with none of them has no chip.
struct ModelTraitsSheet: View {
    let session: AgentSession
    let model: ProviderModel
    let onChoose: (ComposerTraitChange) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        PickerSheet(title: String(localized: "Traits")) {
            if !model.reasoningEfforts.isEmpty {
                Section("Reasoning") {
                    ForEach(model.reasoningEfforts) { option in
                        PickerRow(
                            title: ModelOptionLabel.label(id: option.id, fallback: option.label),
                            subtitle: option.description,
                            suffix: model.defaultReasoningEffort == option.id
                                ? String(localized: "Default") : nil,
                            selected: ComposerTraits.effort(session, model) == option.id
                        ) {
                            onChoose(.reasoningEffort(option.id))
                            dismiss()
                        }
                    }
                }
            }
            if !model.serviceTiers.isEmpty {
                Section("Service Tier") {
                    PickerRow(
                        title: String(localized: "Standard"),
                        suffix: (model.defaultServiceTier ?? "default") == "default"
                            ? String(localized: "Default") : nil,
                        selected: ComposerTraits.tier(session, model) == "default"
                    ) {
                        onChoose(.serviceTier("default"))
                        dismiss()
                    }
                    ForEach(model.serviceTiers) { option in
                        PickerRow(
                            title: ModelOptionLabel.label(id: option.id, fallback: option.label),
                            subtitle: option.description,
                            suffix: model.defaultServiceTier == option.id
                                ? String(localized: "Default") : nil,
                            selected: ComposerTraits.tier(session, model) == option.id
                        ) {
                            onChoose(.serviceTier(option.id))
                            dismiss()
                        }
                    }
                }
            }
            if !model.contextWindows.isEmpty {
                Section("Context Window") {
                    ForEach(model.contextWindows) { option in
                        PickerRow(
                            title: ModelOptionLabel.label(id: option.id, fallback: option.label),
                            subtitle: option.description,
                            suffix: model.defaultContextWindow == option.id
                                ? String(localized: "Default") : nil,
                            selected: ComposerTraits.contextWindow(session, model) == option.id
                        ) {
                            onChoose(.contextWindow(option.id))
                            dismiss()
                        }
                    }
                }
            }
        }
    }
}

/// Which trait a session is actually running with: its own choice when the
/// model still offers it, and the model's default otherwise.
enum ComposerTraits {
    static func effort(_ session: AgentSession, _ model: ProviderModel) -> String? {
        if let effort = session.reasoningEffort,
            model.reasoningEfforts.contains(where: { $0.id == effort })
        {
            return effort
        }
        return model.defaultReasoningEffort ?? model.reasoningEfforts.first?.id
    }

    static func tier(_ session: AgentSession, _ model: ProviderModel) -> String {
        if let tier = session.serviceTier,
            tier == "default" || model.serviceTiers.contains(where: { $0.id == tier })
        {
            return tier
        }
        return model.defaultServiceTier ?? "default"
    }

    static func contextWindow(_ session: AgentSession, _ model: ProviderModel) -> String? {
        if let window = session.contextWindow,
            model.contextWindows.contains(where: { $0.id == window })
        {
            return window
        }
        return model.defaultContextWindow ?? model.contextWindows.first?.id
    }

    /// What the traits chip says: the effort, or the tier when the model has
    /// no efforts, plus a non-default context window because it changes both
    /// cost and capacity.
    static func chipLabel(_ session: AgentSession, _ model: ProviderModel) -> String {
        let tierId = tier(session, model)
        let tierLabel = tierId == "default"
            ? String(localized: "Standard")
            : ModelOptionLabel.label(
                id: tierId,
                fallback: model.serviceTiers.first { $0.id == tierId }?.label ?? tierId
            )
        let effortLabel = effort(session, model)
            .flatMap { id in model.reasoningEfforts.first { $0.id == id } }
            .map { ModelOptionLabel.label(id: $0.id, fallback: $0.label) }
        let window = contextWindow(session, model)
        let windowLabel = window != model.defaultContextWindow
            ? window.flatMap { id in model.contextWindows.first { $0.id == id } }
                .map { ModelOptionLabel.label(id: $0.id, fallback: $0.label) }
            : nil
        let head = effortLabel ?? tierLabel
        return windowLabel.map { "\(head) · \($0)" } ?? head
    }

    static func isFast(_ session: AgentSession, _ model: ProviderModel) -> Bool {
        let id = tier(session, model)
        if id == "fast" { return true }
        return model.serviceTiers.first { $0.id == id }?.label.lowercased() == "fast"
    }

    static func hasAny(_ model: ProviderModel) -> Bool {
        !model.reasoningEfforts.isEmpty || !model.serviceTiers.isEmpty
            || !model.contextWindows.isEmpty
    }
}

struct AgentPresetSheet: View {
    let session: AgentSession
    let presets: [ProviderAgentPreset]
    let onChoose: (ProviderAgentPreset) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        PickerSheet(title: String(localized: "Agent preset")) {
            ForEach(presets, id: \.id) { preset in
                PickerRow(
                    title: AgentPresetCopy.label(preset),
                    subtitle: AgentPresetCopy.description(preset),
                    suffix: preset.isCustom ? String(localized: "Custom") : nil,
                    selected: preset.id == AgentPresets.selected(session, presets)?.id
                ) {
                    onChoose(preset)
                    dismiss()
                }
            }
        }
    }
}

enum AgentPresets {
    static func selected(
        _ session: AgentSession,
        _ presets: [ProviderAgentPreset]
    ) -> ProviderAgentPreset? {
        presets.first { $0.id == session.agentPreset }
            ?? presets.first { $0.isDefault }
            ?? presets.first
    }
}

struct AccessSheet: View {
    let session: AgentSession
    let onChoose: (RuntimeMode) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        PickerSheet(title: String(localized: "Access")) {
            ForEach(AccessMode.all) { mode in
                PickerRow(
                    title: mode.title,
                    subtitle: mode.detail,
                    systemImage: mode.systemImage,
                    selected: mode.id == AccessMode.selected(for: session.runtimeMode).id
                ) {
                    onChoose(mode.id)
                    dismiss()
                }
            }
        }
    }
}

// MARK: - Workspace controls

struct ProjectPickerSheet: View {
    let session: AgentSession
    let projects: [Project]
    let onChoose: (Project) -> Void
    let onBrowse: () -> Void
    let onProjectless: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        PickerSheet(title: String(localized: "Project")) {
            Section {
                ForEach(projects.filter { !$0.isProjectless }) { project in
                    PickerRow(
                        title: project.name,
                        subtitle: project.path,
                        systemImage: "folder",
                        selected: project.id == session.projectId
                    ) {
                        onChoose(project)
                        dismiss()
                    }
                }
            }
            Section {
                Button {
                    dismiss()
                    onBrowse()
                } label: {
                    Label("Browse…", systemImage: "folder.badge.plus")
                }
                Button {
                    dismiss()
                    onProjectless()
                } label: {
                    Label("Don't work in a project", systemImage: "xmark.circle")
                }
            } footer: {
                Text("Browse the folders on your daemon's computer to add a project.")
            }
        }
    }
}

struct WorkspaceKindSheet: View {
    let session: AgentSession
    let projectless: Bool
    let onChoose: (SessionWorkspace) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        PickerSheet(title: String(localized: "Work in")) {
            PickerRow(
                title: String(localized: "Local"),
                subtitle: String(localized: "Work directly in the project's own checkout"),
                systemImage: "laptopcomputer",
                selected: session.workspace.isLocal
            ) {
                onChoose(.local)
                dismiss()
            }
            PickerRow(
                title: String(localized: "New worktree"),
                subtitle: String(
                    localized: "Give this task its own branch and directory, off the base branch"),
                systemImage: "arrow.triangle.branch",
                selected: !session.workspace.isLocal,
                disabled: projectless,
                disabledReason: projectless
                    ? String(localized: "A scratch workspace has no repository to branch from")
                    : nil
            ) {
                onChoose(.newWorktree(baseBranch: nil))
                dismiss()
            }
        }
    }
}

/// Branches for the session's workspace: the base branch a planned worktree
/// will fork from, or the branch a local workspace checks out.
struct BranchPickerSheet: View {
    let session: AgentSession
    let snapshot: BranchSnapshot
    let onSelect: (String) -> Void
    let onCreate: (String) -> Void
    let onRefresh: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var newBranch = ""
    @State private var creating = false
    @FocusState private var newBranchFocused: Bool

    private var plannedWorktree: Bool {
        if case .newWorktree = session.workspace { return true }
        return false
    }

    private var selected: String? {
        switch session.workspace {
        case .newWorktree(let baseBranch):
            return baseBranch ?? snapshot.defaultBranch ?? snapshot.displayBranch
        case .worktree(_, let branch):
            return snapshot.current ?? branch
        default:
            return snapshot.displayBranch
        }
    }

    private var visible: [BranchEntry] {
        let parts = query.lowercased().split(whereSeparator: \.isWhitespace)
        return snapshot.branches
            .filter { branch in
                parts.allSatisfy { branch.name.lowercased().contains($0) }
            }
            .sorted { left, right in
                if left.name == selected { return true }
                if right.name == selected { return false }
                return left.name < right.name
            }
    }

    var body: some View {
        NavigationStack {
            List {
                if creating {
                    Section {
                        TextField("New branch name", text: $newBranch)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                            .focused($newBranchFocused)
                            .submitLabel(.done)
                            .onSubmit(commitCreate)
                        Button("Create and checkout new branch", action: commitCreate)
                            .disabled(newBranch.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                } else {
                    Section {
                        ForEach(visible) { branch in
                            let blocked = branch.checkedOutElsewhere && !plannedWorktree
                                && branch.name != selected
                            PickerRow(
                                title: branch.name,
                                systemImage: "arrow.triangle.branch",
                                selected: branch.name == selected,
                                disabled: blocked,
                                disabledReason: blocked
                                    ? String(localized: "Checked out in another worktree") : nil
                            ) {
                                onSelect(branch.name)
                                dismiss()
                            }
                        }
                        if visible.isEmpty {
                            Text("No branches found")
                                .foregroundStyle(.secondary)
                        }
                    }
                    if !plannedWorktree {
                        Section {
                            Button {
                                creating = true
                                newBranchFocused = true
                            } label: {
                                Label("Create and checkout new branch", systemImage: "plus")
                            }
                        }
                    }
                }
            }
            .searchable(text: $query, prompt: Text("Search branches"))
            .navigationTitle("Branch")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    if creating {
                        Button("Back") { creating = false }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .task { onRefresh() }
    }

    private func commitCreate() {
        let name = newBranch.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        onCreate(name)
        dismiss()
    }
}

// MARK: - Usage

/// What the turn is spending: the session's context window, and the provider's
/// own plan limits when it reports them.
struct UsageSheet: View {
    let session: AgentSession
    let store: SessionStore

    @Environment(\.dismiss) private var dismiss
    @State private var plan: PlanUsage?
    @State private var planError: String?
    @State private var loading = false

    var body: some View {
        PickerSheet(title: String(localized: "Usage")) {
            Section("Context window") {
                UsageLane(
                    label: String(localized: "Context window"),
                    percent: ContextUsagePresentation.percent(session) ?? 0,
                    value: ContextUsagePresentation.detail(session)
                )
            }
            Section {
                if let plan {
                    ForEach(plan.windows) { window in
                        UsageLane(
                            label: window.label,
                            percent: window.percent,
                            value: "\(Int(window.percent.rounded()))%",
                            reset: window.resetsAt.map(UsageResetLabel.label(resetsAt:))
                        )
                    }
                } else if loading {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Loading…").foregroundStyle(.secondary)
                    }
                } else if let planError {
                    Text(planError)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    Text("This provider does not report plan limits.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text(
                    plan?.planLabel.map { String(localized: "Plan usage limits · \($0)") }
                        ?? String(localized: "Plan usage limits"))
            }
        }
        .task {
            loading = true
            defer { loading = false }
            do {
                plan = try await store.planUsage(for: session.provider)
            } catch {
                planError = error.localizedDescription
            }
        }
    }
}

enum ContextUsagePresentation {
    static func percent(_ session: AgentSession) -> Double? {
        guard let usage = session.contextUsage, let window = usage.window, window > 0 else {
            return nil
        }
        return Double(usage.tokens) * 100 / Double(window)
    }

    static func remaining(_ session: AgentSession) -> Double? {
        percent(session).map { min(100, max(0, 100 - $0)) }
    }

    static func detail(_ session: AgentSession) -> String {
        guard let usage = session.contextUsage else { return formatTokens(0) }
        guard let window = usage.window, let percent = percent(session) else {
            return formatTokens(usage.tokens)
        }
        return
            "\(formatTokens(usage.tokens)) / \(formatTokens(window)) (\(Int(percent.rounded()))%)"
    }

    /// Port of `format_tokens` in `crates/shidou-protocol/src/usage.rs`.
    static func formatTokens(_ tokens: UInt64) -> String {
        if tokens >= 999_500 {
            return String(format: "%.1fM", Double(tokens) / 1_000_000)
        }
        if tokens >= 1_000 {
            return String(format: "%.1fk", Double(tokens) / 1_000)
        }
        return "\(tokens)"
    }
}

enum UsageResetLabel {
    static func label(resetsAt: Int64) -> String {
        let seconds = resetsAt - Int64(Date().timeIntervalSince1970)
        if seconds <= 0 { return String(localized: "Resets soon") }
        let minutes = Int((seconds + 59) / 60)
        if minutes < 60 { return String(localized: "Resets in \(minutes) min") }
        if minutes < 24 * 60 {
            let hours = minutes / 60
            let remainder = minutes % 60
            return remainder == 0
                ? String(localized: "Resets in \(hours) h")
                : String(localized: "Resets in \(hours) h \(remainder) min")
        }
        let date = Date(timeIntervalSince1970: TimeInterval(resetsAt))
        return String(
            localized: "Resets \(date.formatted(.dateTime.weekday(.abbreviated).hour().minute()))")
    }
}

struct UsageLane: View {
    let label: String
    let percent: Double
    let value: String
    var reset: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(label)
                Spacer(minLength: 8)
                if let reset {
                    Text(reset).font(.caption).foregroundStyle(.secondary)
                }
                Text(value).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            ProgressView(value: min(100, max(0, percent)), total: 100)
                .tint(percent >= 95 ? .red : percent >= 80 ? .orange : .accentColor)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(verbatim: "\(label), \(value)"))
    }
}

/// The composer's context gauge: a ring, plus the percentage in words. The
/// number is what carries the meaning — the colour only reinforces it.
struct ContextGauge: View {
    let percent: Double?

    @ScaledMetric(relativeTo: .footnote) private var size: CGFloat = 13

    var body: some View {
        ZStack {
            Circle()
                .stroke(.quaternary, lineWidth: 2.5)
            if let percent {
                Circle()
                    .trim(from: 0, to: min(1, max(0.05, percent / 100)))
                    .stroke(tint, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    private var tint: Color {
        guard let percent else { return .secondary }
        if percent >= 95 { return .red }
        if percent >= 80 { return .orange }
        return .secondary
    }
}
