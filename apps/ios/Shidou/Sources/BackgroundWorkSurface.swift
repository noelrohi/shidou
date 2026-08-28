import ShidouProtocol
import ShidouSession
import SwiftUI

/// Processes, monitors and subagents, each with a stop.
///
/// This is the one surface here that is not read-only, because stopping a
/// runaway process from a phone is the reason to have it at all.
struct BackgroundWorkView: View {
    let session: AgentSession
    let model: SessionRuntimeModel
    let store: SessionStore

    @State private var stopError: String?
    @State private var refreshError: String?

    var body: some View {
        List {
            ForEach(model.backgroundWork.ordered) { item in
                NavigationLink(value: SurfaceRoute.work(key: item.key)) {
                    BackgroundWorkRow(item: item)
                }
                .swipeActions(edge: .trailing) {
                    if item.canStop && item.status.isStoppable {
                        Button("Stop", role: .destructive) { stop(item) }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        // An empty ledger and a refresh that never landed look the same on
        // screen, so the error branch of the ladder is what keeps a failure
        // from claiming there is nothing running.
        .surfaceState(
            isEmpty: model.backgroundWork.isEmpty,
            isLoading: false,
            error: refreshError,
            retry: { Task { await refresh() } },
            failureTitle: "Could not read the background work",
            failureIcon: "gearshape.2"
        ) {
            ContentUnavailableView(
                "Nothing in the background", systemImage: "gearshape.2",
                description: Text("Processes, monitors and subagents this task started show up here."))
        }
        .navigationTitle("Background Work")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await refresh() }
        // The ledger is rebuilt from events, and replay skips the ones the
        // stored transcript already counted — so a snapshot on arrival is what
        // makes this panel true on the visit that matters.
        .task { await refresh() }
        .alert(
            "Could not stop it",
            isPresented: Binding(get: { stopError != nil }, set: { if !$0 { stopError = nil } })
        ) {
            Button("OK") { stopError = nil }
        } message: {
            Text(stopError ?? "")
        }
    }

    private func refresh() async {
        do {
            try await store.refreshBackgroundWork(session.id)
            refreshError = nil
        } catch {
            refreshError = error.localizedDescription
        }
    }

    private func stop(_ item: BackgroundWorkItem) {
        Task {
            do {
                try await store.stopBackgroundWork(session.id, item: item)
            } catch {
                stopError = error.localizedDescription
            }
        }
    }
}

struct BackgroundWorkRow: View {
    let item: BackgroundWorkItem

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: BackgroundWorkPresentation.symbol(item.key.kind))
                .font(.footnote)
                .foregroundStyle(.secondary)
                .frame(width: 20)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: item.title).lineLimit(2)
                HStack(spacing: 6) {
                    BackgroundWorkStatusLabel(status: item.status)
                    if let detail = item.detail, !detail.isEmpty {
                        Text(verbatim: detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .frame(minHeight: 44)
        .accessibilityElement(children: .combine)
    }
}

/// Status is a word and a symbol, never a colour alone.
struct BackgroundWorkStatusLabel: View {
    let status: BackgroundWorkStatus

    var body: some View {
        Label {
            Text(BackgroundWorkPresentation.label(status))
        } icon: {
            Image(systemName: BackgroundWorkPresentation.statusSymbol(status))
        }
        .labelStyle(.titleAndIcon)
        .font(.caption)
        .foregroundStyle(BackgroundWorkPresentation.tint(status))
    }
}

enum BackgroundWorkPresentation {
    static func symbol(_ kind: BackgroundWorkKind) -> String {
        switch kind {
        case .process: return "terminal"
        case .monitor: return "eye"
        case .subagent: return "person.2"
        case .unknown: return "questionmark.circle"
        }
    }

    static func kindLabel(_ kind: BackgroundWorkKind) -> LocalizedStringKey {
        switch kind {
        case .process: return "Process"
        case .monitor: return "Monitor"
        case .subagent: return "Subagent"
        case .unknown: return "Work"
        }
    }

    static func statusSymbol(_ status: BackgroundWorkStatus) -> String {
        switch status {
        case .starting, .running: return "play.circle"
        case .monitoring: return "eye.circle"
        case .stopping: return "stop.circle"
        case .completed: return "checkmark.circle"
        case .failed: return "xmark.circle"
        case .stopped: return "minus.circle"
        case .lost, .unknown: return "questionmark.circle"
        }
    }

    static func label(_ status: BackgroundWorkStatus) -> LocalizedStringKey {
        switch status {
        case .starting: return "Starting"
        case .running: return "Running"
        case .monitoring: return "Monitoring"
        case .stopping: return "Stopping"
        case .completed: return "Completed"
        case .failed: return "Failed"
        case .stopped: return "Stopped"
        case .lost: return "Lost"
        case .unknown: return "Unknown"
        }
    }

    static func tint(_ status: BackgroundWorkStatus) -> Color {
        switch status {
        case .starting, .running, .monitoring: return .green
        case .stopping: return .orange
        case .completed: return .secondary
        case .failed: return .red
        case .stopped, .lost, .unknown: return .secondary
        }
    }
}

/// One piece of background work: what it is, where it ran, and its output.
struct BackgroundWorkDetailView: View {
    let session: AgentSession
    let model: SessionRuntimeModel
    let store: SessionStore
    let key: BackgroundWorkKey

    @State private var stopError: String?

    private var item: BackgroundWorkItem? { model.backgroundWork.item(for: key) }

    var body: some View {
        Group {
            if let item {
                List {
                    Section {
                        LabeledContent("Kind") {
                            Text(BackgroundWorkPresentation.kindLabel(item.key.kind))
                        }
                        LabeledContent("Status") {
                            BackgroundWorkStatusLabel(status: item.status)
                        }
                        if let exitCode = item.exitCode {
                            LabeledContent("Exit code", value: "\(exitCode)")
                        }
                        if let duration = item.durationMs {
                            LabeledContent("Duration", value: durationLabel(duration))
                        }
                        if let model = item.model {
                            LabeledContent("Model", value: model)
                        }
                        if let role = item.role {
                            LabeledContent("Role", value: role)
                        }
                    }
                    if let command = item.command, !command.isEmpty {
                        Section("Command") {
                            Text(verbatim: command)
                                .font(.system(.footnote, design: .monospaced))
                                .textSelection(.enabled)
                        }
                    }
                    if let cwd = item.cwd, !cwd.isEmpty {
                        Section("Directory") {
                            Text(verbatim: cwd)
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                        }
                    }
                    if let output = item.output, !output.isEmpty {
                        Section {
                            Text(verbatim: output)
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                        } header: {
                            Text("Output")
                        } footer: {
                            if item.outputTruncated {
                                Text("Only the most recent output is kept.")
                            }
                        }
                    }
                    if item.canStop && item.status.isStoppable {
                        Section {
                            Button("Stop", role: .destructive) { stop(item) }
                        }
                    }
                }
            } else {
                ContentUnavailableView(
                    "This work is no longer listed", systemImage: "gearshape.2")
            }
        }
        .navigationTitle(item?.title ?? "Background Work")
        .navigationBarTitleDisplayMode(.inline)
        .alert(
            "Could not stop it",
            isPresented: Binding(get: { stopError != nil }, set: { if !$0 { stopError = nil } })
        ) {
            Button("OK") { stopError = nil }
        } message: {
            Text(stopError ?? "")
        }
    }

    private func durationLabel(_ milliseconds: UInt64) -> String {
        let seconds = Double(milliseconds) / 1000
        if seconds < 60 { return String(format: "%.1fs", seconds) }
        return "\(Int(seconds) / 60)m \(Int(seconds) % 60)s"
    }

    private func stop(_ item: BackgroundWorkItem) {
        Task {
            do {
                try await store.stopBackgroundWork(session.id, item: item)
            } catch {
                stopError = error.localizedDescription
            }
        }
    }
}
