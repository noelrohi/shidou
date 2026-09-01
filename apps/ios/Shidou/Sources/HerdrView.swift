import ShidouProtocol
import ShidouSession
import SwiftUI

struct HerdrView: View {
    @Environment(DaemonConnection.self) private var connection

    private var store: SessionStore? { connection.sessions }

    var body: some View {
        List {
            if let store, store.herdr.available {
                ForEach(store.herdr.workspaces) { workspace in
                    Section(workspace.label) {
                        let agents = store.herdr.agents.filter { $0.workspaceId == workspace.id }
                        if agents.isEmpty {
                            Text("No active agents")
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(agents) { agent in
                                NavigationLink(value: agent.terminalId) {
                                    HerdrAgentRow(agent: agent)
                                }
                            }
                        }
                    }
                }
            }
        }
        .overlay { emptyState }
        .navigationTitle("Herdr")
        .navigationDestination(for: String.self) { terminalId in
            if let agent = store?.herdr.agents.first(where: { $0.terminalId == terminalId }) {
                HerdrAgentView(agent: agent)
            } else {
                ContentUnavailableView("Agent unavailable", systemImage: "terminal")
            }
        }
        .refreshable { store?.refreshHerdr() }
        .task { store?.refreshHerdr() }
    }

    @ViewBuilder
    private var emptyState: some View {
        if let error = store?.herdrError {
            ContentUnavailableView {
                Label("Could not load Herdr", systemImage: "exclamationmark.triangle")
            } description: {
                Text(error)
            } actions: {
                Button("Try again") { store?.refreshHerdr() }
            }
        } else if let store, !store.isLoadingHerdr, !store.herdr.available {
            ContentUnavailableView {
                Label("Herdr is not connected", systemImage: "terminal")
            } description: {
                Text(store.herdr.unavailableReason ?? "Start Herdr on the computer running the Shidou daemon.")
            } actions: {
                Button("Try again") { store.refreshHerdr() }
            }
        } else if store?.isLoadingHerdr == true {
            ProgressView()
        }
    }
}

private struct HerdrAgentRow: View {
    let agent: HerdrAgent

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: statusSymbol)
                .foregroundStyle(statusColor)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(agent.displayTitle)
                    .lineLimit(1)
                Text("\(agent.agent) · \(statusLabel)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var statusLabel: String { agent.status.rawValue.capitalized }

    private var statusSymbol: String {
        switch agent.status {
        case .working: "circle.dotted"
        case .blocked: "exclamationmark.circle.fill"
        case .done: "checkmark.circle.fill"
        case .idle: "circle"
        case .unknown: "questionmark.circle"
        }
    }

    private var statusColor: Color {
        switch agent.status {
        case .working: .blue
        case .blocked: .orange
        case .done: .green
        case .idle, .unknown: .secondary
        }
    }
}

private struct HerdrAgentView: View {
    @Environment(DaemonConnection.self) private var connection

    let agent: HerdrAgent

    @State private var output = ""
    @State private var revision: UInt64 = 0
    @State private var prompt = ""
    @State private var error: String?
    @State private var sending = false

    private var store: SessionStore? { connection.sessions }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                Text(output.isEmpty ? "Waiting for terminal output…" : output)
                    .font(.system(.footnote, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding()
            }
            Divider()
            HStack(alignment: .bottom, spacing: 8) {
                TextField("Prompt agent", text: $prompt, axis: .vertical)
                    .lineLimit(1...5)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { sendPrompt() }
                Button("Send", systemImage: "arrow.up.circle.fill") { sendPrompt() }
                    .labelStyle(.iconOnly)
                    .font(.title2)
                    .disabled(sending || prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding()
        }
        .navigationTitle(agent.displayTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button("Escape", systemImage: "escape") { sendKeys(["esc"]) }
                Button("Interrupt", systemImage: "stop.circle") { sendKeys(["ctrl+c"]) }
            }
        }
        .task { await followOutput() }
        .alert("Herdr command failed", isPresented: Binding(
            get: { error != nil },
            set: { if !$0 { error = nil } }
        )) {
            Button("OK") { error = nil }
        } message: {
            Text(error ?? "")
        }
    }

    private func followOutput() async {
        while !Task.isCancelled {
            await refreshOutput()
            try? await Task.sleep(for: .seconds(2))
        }
    }

    private func refreshOutput() async {
        guard let store else { return }
        do {
            let next = try await store.readHerdrAgent(agent.terminalId)
            if next.revision != revision || output.isEmpty {
                output = next.text
                revision = next.revision
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func sendPrompt() {
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let store else { return }
        prompt = ""
        sending = true
        Task {
            defer { sending = false }
            do {
                try await store.promptHerdrAgent(agent.terminalId, prompt: text)
                await refreshOutput()
            } catch {
                self.error = error.localizedDescription
                prompt = text
            }
        }
    }

    private func sendKeys(_ keys: [String]) {
        guard let store else { return }
        Task {
            do {
                try await store.sendHerdrKeys(agent.terminalId, keys: keys)
                await refreshOutput()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}
