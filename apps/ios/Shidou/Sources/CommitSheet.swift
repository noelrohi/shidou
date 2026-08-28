import ShidouProtocol
import ShidouSession
import SwiftUI

/// Commit and push, with the message written by an agent.
///
/// The daemon does commit-and-push under one lock, so pushing is a toggle here
/// rather than a second trip the phone would have to sequence itself. Nothing
/// stages: the include-unstaged switch is the whole staging model the desktop
/// exposes too.
struct CommitSheet: View {
    let session: AgentSession
    let store: SessionStore
    let cwd: String

    @Environment(\.dismiss) private var dismiss

    @State private var snapshot: CommitSnapshot?
    @State private var message = ""
    @State private var includeUnstaged = true
    @State private var push = false
    @State private var isGenerating = false
    @State private var isCommitting = false
    @State private var error: String?
    @FocusState private var messageFocused: Bool

    private var hasSomethingToCommit: Bool {
        guard let snapshot else { return false }
        return snapshot.hasStaged || (includeUnstaged && snapshot.hasUnstaged)
    }

    private var canCommit: Bool {
        !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && hasSomethingToCommit
            && !isCommitting
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if let snapshot {
                        LabeledContent("Branch", value: snapshot.branch)
                        LabeledContent("Staged", value: "+\(snapshot.stagedAdditions) −\(snapshot.stagedDeletions)")
                        LabeledContent("Unstaged", value: "+\(snapshot.additions) −\(snapshot.deletions)")
                    } else {
                        HStack {
                            ProgressView().controlSize(.small)
                            Text("Reading the repository…").foregroundStyle(.secondary)
                        }
                    }
                }

                Section {
                    TextField("Message", text: $message, axis: .vertical)
                        .lineLimit(4...12)
                        .focused($messageFocused)
                        .disabled(isCommitting)
                    Button {
                        generate()
                    } label: {
                        if isGenerating {
                            HStack {
                                ProgressView().controlSize(.small)
                                Text("Writing…")
                            }
                        } else {
                            Label("Write it for me", systemImage: "sparkles")
                        }
                    }
                    .disabled(isGenerating || isCommitting || !hasSomethingToCommit)
                    .keyboardShortcut("g", modifiers: .command)
                } header: {
                    Text("Message")
                } footer: {
                    Text("The agent reads the diff on your Mac and writes the message there. Nothing is sent anywhere else.")
                }

                Section {
                    Toggle("Include unstaged changes", isOn: $includeUnstaged)
                        .disabled(isCommitting)
                    Toggle("Push after committing", isOn: $push)
                        .disabled(isCommitting || snapshot?.canPush != true)
                }

                if let error {
                    Section {
                        Label {
                            Text(error).font(.footnote)
                        } icon: {
                            Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                        }
                    }
                }

                if snapshot?.canPush == true, !hasSomethingToCommit {
                    Section {
                        Button("Push without committing") { pushOnly() }
                            .disabled(isCommitting)
                    }
                }
            }
            .navigationTitle("Commit")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(isCommitting)
                        .keyboardShortcut(.cancelAction)
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isCommitting {
                        ProgressView().controlSize(.small)
                    } else {
                        Button(push ? "Commit & Push" : "Commit") { commit() }
                            .disabled(!canCommit)
                            .keyboardShortcut(.defaultAction)
                    }
                }
            }
            .task { await refresh() }
        }
    }

    private func refresh() async {
        do {
            let fresh = try await store.inspectCommit(cwd: cwd)
            snapshot = fresh
            if !fresh.canPush { push = false }
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func generate() {
        isGenerating = true
        error = nil
        Task {
            do {
                message = try await store.generateCommitMessage(
                    cwd: cwd, session: session, includeUnstaged: includeUnstaged)
            } catch {
                self.error = error.localizedDescription
            }
            isGenerating = false
        }
    }

    private func commit() {
        isCommitting = true
        error = nil
        Task {
            do {
                _ = try await store.commit(
                    cwd: cwd,
                    message: message.trimmingCharacters(in: .whitespacesAndNewlines),
                    includeUnstaged: includeUnstaged,
                    push: push
                )
                dismiss()
            } catch {
                self.error = error.localizedDescription
                isCommitting = false
            }
        }
    }

    private func pushOnly() {
        isCommitting = true
        error = nil
        Task {
            do {
                _ = try await store.push(cwd: cwd)
                dismiss()
            } catch {
                self.error = error.localizedDescription
                isCommitting = false
            }
        }
    }
}
