import ShidouClient
import ShidouProtocol
import ShidouSession
import SwiftUI

/// Which appearance the app should use, independent of the system's.
///
/// Stored on the phone rather than in daemon settings: the daemon strips
/// `theme` and `language` out of its own file precisely because they belong to
/// whichever client is reading, and a phone in a dark room should not have to
/// agree with a Mac in a bright one.
enum ThemeChoice: String, CaseIterable, Identifiable {
    case system, light, dark

    var id: String { rawValue }

    var label: LocalizedStringKey {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }

    static let storageKey = "shidou.theme"
}

/// Settings, as a modal stack of six pages.
///
/// Daemon shipped with the pairing slice and is extended here rather than
/// rebuilt. About sits outside the paired branch so a reviewer reaches the
/// privacy policy before pairing — guideline 5.1.1 wants it reachable inside
/// the app, and "inside" cannot mean "after you own a Mac".
struct SettingsView: View {
    let done: () -> Void

    @Environment(DaemonConnection.self) private var connection

    var body: some View {
        List {
            if connection.sessions != nil {
                Section {
                    NavigationLink {
                        GeneralSettingsView()
                    } label: {
                        Label("General", systemImage: "gearshape")
                    }
                    NavigationLink {
                        AppearanceSettingsView()
                    } label: {
                        Label("Appearance", systemImage: "paintbrush")
                    }
                    NavigationLink {
                        ProvidersSettingsView()
                    } label: {
                        Label("Providers", systemImage: "cpu")
                    }
                    NavigationLink {
                        SkillsSettingsView()
                    } label: {
                        Label("Skills", systemImage: "wand.and.stars")
                    }
                    NavigationLink {
                        UsageSettingsView()
                    } label: {
                        Label("Usage", systemImage: "chart.bar")
                    }
                }
            }
            Section {
                NavigationLink {
                    DaemonSettingsView()
                } label: {
                    Label("Daemon", systemImage: "desktopcomputer")
                }
            }
            Section {
                NavigationLink {
                    AboutView()
                } label: {
                    Label("About", systemImage: "info.circle")
                }
            } footer: {
                Text("Shidou \(ShidouApp.versionLabel) · protocol v\(ShidouWire.protocolVersion)")
            }
        }
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done", action: done)
                    .keyboardShortcut(.cancelAction)
            }
        }
    }
}

// MARK: - General

private struct GeneralSettingsView: View {
    @Environment(DaemonConnection.self) private var connection

    @State private var settings: DaemonSettings?
    @State private var error: String?

    private var store: SessionStore? { connection.sessions }

    var body: some View {
        Form {
            Section {
                Text("Tasks, projects and transcripts live on the Mac you paired with. This phone keeps only that Mac's address and its token.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Local by default")
            }

            Section {
                Toggle(
                    "Conventional commit messages",
                    isOn: Binding(
                        get: { settings?.conventionalCommitMessages ?? false },
                        set: { setConventionalCommits($0) }
                    )
                )
                .disabled(settings == nil)
            } footer: {
                Text("Ask the agent for a `type(scope): subject` first line when it writes a commit message.")
            }

            Section {
                Text("Shidou for iOS collects nothing and talks to no server of its own.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Privacy")
            }

            Section("Legal") {
                Link(destination: URL(string: "https://shidou.dev/privacy")!) {
                    ExternalRow(title: "Privacy Policy")
                }
                Link(destination: URL(string: "https://github.com/noelrohi/shidou/blob/master/LICENSE")!) {
                    ExternalRow(title: "License")
                }
                Link(destination: URL(string: "https://github.com/noelrohi/shidou/blob/master/THIRD_PARTY_NOTICES.md")!) {
                    ExternalRow(title: "Third-party licenses")
                }
                Link(destination: URL(string: "https://github.com/noelrohi/shidou")!) {
                    ExternalRow(title: "Source code")
                }
            }

            if let error {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }
            }
        }
        .navigationTitle("General")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
    }

    private func load() async {
        guard let store else { return }
        do {
            settings = try await store.reloadSettings()
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func setConventionalCommits(_ enabled: Bool) {
        guard let store, var next = settings else { return }
        next.conventionalCommitMessages = enabled
        settings = next
        Task {
            do {
                try await store.updateSettings(next)
                error = nil
            } catch {
                self.error = error.localizedDescription
                settings = store.settings
            }
        }
    }
}

// MARK: - Appearance

private struct AppearanceSettingsView: View {
    @AppStorage(ThemeChoice.storageKey) private var theme = ThemeChoice.system.rawValue
    @Environment(\.openURL) private var openURL

    var body: some View {
        Form {
            Section {
                Picker("Theme", selection: $theme) {
                    ForEach(ThemeChoice.allCases) { choice in
                        Text(choice.label).tag(choice.rawValue)
                    }
                }
                .pickerStyle(.inline)
            } header: {
                Text("Theme")
            } footer: {
                Text("System follows the phone's own light and dark setting.")
            }

            Section {
                Button {
                    // iOS owns per-app language: the system Settings page for
                    // an app with several localizations has a Language row,
                    // and it is the only override that applies everywhere
                    // rather than only to text SwiftUI happens to resolve.
                    // A picker here would leave half the app in the old
                    // language until the next launch.
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        openURL(url)
                    }
                } label: {
                    LabeledContent("Language") {
                        HStack(spacing: 4) {
                            Text(currentLanguageName)
                            Image(systemName: "arrow.up.right")
                                .font(.footnote)
                        }
                        .foregroundStyle(.secondary)
                    }
                }
                .accessibilityHint("Opens Shidou in the Settings app")
            } footer: {
                Text("Shidou is translated into English, Japanese, Filipino and Simplified Chinese. iOS keeps the choice, in Settings.")
            }
        }
        .navigationTitle("Appearance")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var currentLanguageName: String {
        let identifier = Bundle.main.preferredLocalizations.first ?? "en"
        return Locale.current.localizedString(forIdentifier: identifier)
            ?? Locale(identifier: identifier).identifier
    }
}

// MARK: - Providers

private struct ProvidersSettingsView: View {
    @Environment(DaemonConnection.self) private var connection

    @State private var settings: DaemonSettings?
    @State private var probes: [ProviderKind: ProviderProbe] = [:]
    @State private var isRefreshing = false
    @State private var error: String?
    @State private var editing: ProviderKind?
    @State private var draftPath = ""

    private var store: SessionStore? { connection.sessions }

    var body: some View {
        Form {
            Section {
                ForEach(ProviderKind.selectable, id: \.self) { provider in
                    ProviderRow(
                        provider: provider,
                        probe: probes[provider],
                        isEnabled: settings?.isEnabled(provider) ?? true,
                        override: settings?.binaryOverride(for: provider),
                        setEnabled: { setEnabled($0, for: provider) },
                        edit: {
                            draftPath = settings?.binaryOverride(for: provider) ?? ""
                            editing = provider
                        }
                    )
                }
            } header: {
                Text("Coding agents")
            } footer: {
                Text("Agents run on the Mac you paired with. Turning one off hides it from the model picker; it does not uninstall anything.")
            }

            if let error {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }
            }
        }
        .navigationTitle("Providers")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if isRefreshing {
                    ProgressView().controlSize(.small)
                } else {
                    Button {
                        Task { await refresh(force: true) }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .accessibilityLabel("Check again")
                }
            }
        }
        .task { await refresh(force: false) }
        .sheet(item: $editing) { provider in
            BinaryOverrideSheet(
                provider: provider,
                path: $draftPath,
                save: { setOverride(draftPath, for: provider) }
            )
        }
    }

    private func refresh(force: Bool) async {
        guard let store else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            settings = force ? try await store.reloadSettings() : try await store.loadSettings()
            var found: [ProviderKind: ProviderProbe] = [:]
            for provider in ProviderKind.selectable {
                found[provider] = try? await store.loadProbe(provider)
            }
            probes = found
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func setEnabled(_ enabled: Bool, for provider: ProviderKind) {
        guard var next = settings else { return }
        next.setEnabled(enabled, for: provider)
        apply(next)
    }

    private func setOverride(_ path: String, for provider: ProviderKind) {
        guard var next = settings else { return }
        next.setBinaryOverride(path, for: provider)
        apply(next)
    }

    private func apply(_ next: DaemonSettings) {
        guard let store else { return }
        let previous = settings
        settings = next
        Task {
            do {
                try await store.updateSettings(next)
                error = nil
                // A changed override or a re-enabled provider changes what a
                // probe answers, so the rows have to be re-read rather than
                // left showing the old verdict.
                await refresh(force: false)
            } catch {
                self.error = error.localizedDescription
                settings = previous
            }
        }
    }
}

extension ProviderKind: @retroactive Identifiable {
    public var id: String { rawValue }
}

private struct ProviderRow: View {
    let provider: ProviderKind
    let probe: ProviderProbe?
    let isEnabled: Bool
    let override: String?
    let setEnabled: (Bool) -> Void
    let edit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle(isOn: Binding(get: { isEnabled }, set: setEnabled)) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(provider.displayName)
                    // Installed-ness is a word, not a dot: a status that only
                    // exists as a colour is invisible to half its readers.
                    Label {
                        Text(statusText)
                    } icon: {
                        Image(systemName: statusSymbol)
                    }
                    .labelStyle(.titleAndIcon)
                    .font(.caption)
                    .foregroundStyle(statusTint)
                }
            }
            .disabled(probe == nil)
            Button(action: edit) {
                HStack(spacing: 4) {
                    Image(systemName: "terminal")
                    Text(override ?? probe?.path ?? String(localized: "Set the path…"))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .frame(minHeight: 32)
            .contentShape(Rectangle())
            .accessibilityLabel("Binary path for \(provider.displayName)")
            .accessibilityHint("Overrides where the daemon looks for the agent")
        }
        .padding(.vertical, 2)
    }

    private var statusText: LocalizedStringKey {
        guard let probe else { return "Checking…" }
        if !probe.installed { return "Not installed" }
        if !isEnabled { return "Installed, turned off" }
        return "^[\(probe.models.count) model](inflect: true)"
    }

    private var statusSymbol: String {
        guard let probe else { return "clock" }
        if !probe.installed { return "xmark.circle" }
        return isEnabled ? "checkmark.circle" : "pause.circle"
    }

    private var statusTint: Color {
        guard let probe else { return .secondary }
        if !probe.installed { return .secondary }
        return isEnabled ? .green : .orange
    }
}

private struct BinaryOverrideSheet: View {
    let provider: ProviderKind
    @Binding var path: String
    let save: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(
                        text: $path,
                        prompt: Text(verbatim: "/opt/homebrew/bin/…")  // an example, not a sentence
                    ) {
                        EmptyView()
                    }
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .font(.body.monospaced())
                } footer: {
                    Text("An absolute path on the Mac. Leave it empty to let the daemon find the agent on its own PATH.")
                }
            }
            .navigationTitle(provider.displayName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .keyboardShortcut(.cancelAction)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        save()
                        dismiss()
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
        }
        .presentationDetents([.medium])
    }
}

// MARK: - About

struct AboutView: View {
    var body: some View {
        Form {
            Section {
                LabeledContent("Version", value: ShidouApp.versionLabel)
                LabeledContent("Protocol", value: "v\(ShidouWire.protocolVersion)")
            }
            Section {
                Link(destination: URL(string: "https://shidou.dev/privacy")!) {
                    ExternalRow(title: "Privacy Policy")
                }
                Link(destination: URL(string: "https://github.com/noelrohi/shidou")!) {
                    ExternalRow(title: "Source code")
                }
                Link(destination: URL(string: "mailto:testflight@shidou.dev")!) {
                    ExternalRow(title: "Send feedback")
                }
            } footer: {
                Text("Shidou connects only to a daemon you run. It has no server of its own and collects nothing.")
            }
        }
        .navigationTitle("About")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct ExternalRow: View {
    let title: LocalizedStringKey

    var body: some View {
        LabeledContent(title) {
            Image(systemName: "arrow.up.right")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .accessibilityHint("Opens outside Shidou")
    }
}
