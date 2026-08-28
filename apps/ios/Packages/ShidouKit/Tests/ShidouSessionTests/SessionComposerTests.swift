import Foundation
import ShidouClient
import ShidouProtocol
import XCTest

@testable import ShidouSession

/// The composer's whole conversation with a daemon, driven against a real
/// `shidou-demo`.
///
/// The scripted showcase is what makes this possible end to end: it streams,
/// it asks for permission, it asks a multi-question form, and it finishes — so
/// a test can send a prompt from a task it just created and watch every step
/// the phone will take, over the real wire, with no fake in the middle.
@MainActor
final class SessionComposerTests: XCTestCase {
    private let demoSession = UUID(uuidString: "5eed0000-0000-0000-0000-000000020001")!

    private var daemon: DemoDaemonProcess?
    private var supervisor: ConnectionSupervisor?
    private var store: SessionStore?

    override func tearDown() async throws {
        store?.stop()
        if let supervisor { await supervisor.stop() }
        daemon?.stop()
        store = nil
        supervisor = nil
        daemon = nil
        try await super.tearDown()
    }

    private func connect() async throws -> SessionStore {
        let daemon = try DemoDaemonProcess()
        self.daemon = daemon
        let supervisor = ConnectionSupervisor(
            endpoint: try DaemonEndpoint(address: daemon.address, token: daemon.token)
        )
        self.supervisor = supervisor
        let store = SessionStore(supervisor: supervisor)
        self.store = store
        store.start()
        await supervisor.start()
        try await waitUntil("the catalog loads") { store.hasLoadedCatalog }
        return store
    }

    private func waitUntil(
        _ description: String,
        timeout: TimeInterval = 30,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ condition: @MainActor () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTFail("timed out waiting for \(description)", file: file, line: line)
        throw XCTSkip("timed out waiting for \(description)")
    }

    /// A task the user just made with ＋: local until its first prompt, which
    /// is what the draft contract means.
    private func newDraft(in store: SessionStore) throws -> SessionRuntimeModel {
        let project = try XCTUnwrap(store.projects.first)
        let draft = store.draftSession(projectId: project.id, provider: .claude)
        return store.adopt(draft)
    }

    // MARK: - Sending

    func testANewTaskMaterializesOnItsFirstPromptAndStreamsTheReply() async throws {
        let store = try await connect()
        let model = try newDraft(in: store)
        XCTAssertFalse(model.session.hasStarted, "a draft has nothing on the daemon yet")

        try await store.send(prompt: "Where is the rate limiting?", to: model)

        XCTAssertTrue(model.currentProjection.hasStarted)
        XCTAssertEqual(model.currentProjection.messages.first?.role, .user)
        try await waitUntil("the reply streams in") {
            model.session.messages.contains { $0.role == .assistant && !$0.content.isEmpty }
        }
        // The task reached the catalog too, or the list would not show it.
        XCTAssertTrue(store.sessions.contains { $0.id == model.session.id })
    }

    func testAPromptSentWhileTheAgentIsWorkingIsQueuedAndCanBeRemoved() async throws {
        let store = try await connect()
        let model = try newDraft(in: store)
        try await store.send(prompt: "Start the showcase", to: model)
        try await waitUntil("the turn is running") { model.session.status.isBusy }

        try await store.send(prompt: "and then the tests", to: model)
        XCTAssertEqual(model.currentProjection.queuedMessages.count, 1)
        XCTAssertEqual(
            model.currentProjection.queuedMessages.first?.visibleContent, "and then the tests")

        let queued = try XCTUnwrap(model.currentProjection.queuedMessages.first)
        try await store.removeQueuedMessage(model, messageId: queued.id)
        XCTAssertTrue(model.currentProjection.queuedMessages.isEmpty)
    }

    func testSteeringAddsTheMessageToTheRunningTurn() async throws {
        let store = try await connect()
        let model = try newDraft(in: store)
        try await store.send(prompt: "Start the showcase", to: model)
        try await waitUntil("the provider acknowledges the turn") {
            model.session.hasActiveProviderTurn
        }

        let before = model.currentProjection.messages.count
        try await store.steer(prompt: "actually, check the tests too", to: model)
        try await waitUntil("the steer lands in the transcript") {
            model.session.messages.count > before
                && model.session.messages.last?.content == "actually, check the tests too"
        }
    }

    func testCancellingEndsTheTurn() async throws {
        let store = try await connect()
        let model = try newDraft(in: store)
        try await store.send(prompt: "Start the showcase", to: model)
        try await waitUntil("the turn is running") { model.session.status.isBusy }

        try await store.cancel(model)
        try await waitUntil("the turn stops") { !model.session.status.isBusy }
    }

    // MARK: - Permissions and questions

    func testThePermissionAndTheQuestionFormBothUnblockTheTurn() async throws {
        let store = try await connect()
        let model = try newDraft(in: store)
        try await store.send(prompt: "Fix the limiter", to: model)

        try await waitUntil("the scripted permission arrives") {
            model.pendingPermission != nil
        }
        let permission = try XCTUnwrap(model.pendingPermission)
        let allow = try XCTUnwrap(permission.options.first { $0.allow })
        try await store.respond(model, requestId: permission.requestId, optionId: allow.id)
        XCTAssertNil(model.pendingPermission)

        try await waitUntil("the question form arrives") { model.pendingUserInput != nil }
        let question = try XCTUnwrap(model.pendingUserInput)
        try await store.respondUserInput(
            model,
            requestId: question.requestId,
            answers: question.questions.map {
                UserInputAnswer(
                    questionId: $0.id, answers: [$0.options.first?.label ?? "yes"])
            }
        )
        XCTAssertNil(model.pendingUserInput)

        try await waitUntil("the turn finishes") { model.session.status == .idle }
    }

    func testAttentionEventsCarryThePermissionTheQuestionAndTheFinishedTurn() async throws {
        let store = try await connect()
        let model = try newDraft(in: store)

        // Collected on a task of its own: attention is what a notification is
        // built from, and it has to arrive without anyone looking at a screen.
        var seen: [AttentionEvent] = []
        let collector = Task { @MainActor in
            for await event in store.attentionEvents() { seen.append(event) }
        }
        defer { collector.cancel() }

        try await store.send(prompt: "Fix the limiter", to: model)
        try await waitUntil("a permission raises attention") {
            seen.contains { if case .permission = $0 { return true } else { return false } }
        }
        let permission = try XCTUnwrap(model.pendingPermission)
        let allow = try XCTUnwrap(permission.options.first { $0.allow })
        try await store.respond(model, requestId: permission.requestId, optionId: allow.id)

        try await waitUntil("a question raises attention") {
            seen.contains {
                if case .userInputRequested = $0 { return true } else { return false }
            }
        }
        let question = try XCTUnwrap(model.pendingUserInput)
        try await store.respondUserInput(
            model,
            requestId: question.requestId,
            answers: question.questions.map {
                UserInputAnswer(questionId: $0.id, answers: [$0.options.first?.label ?? "yes"])
            }
        )

        try await waitUntil("the finished turn raises attention") {
            seen.contains { if case .turnFinished = $0 { return true } else { return false } }
        }
        XCTAssertTrue(seen.allSatisfy { $0.sessionId == model.session.id })
        XCTAssertEqual(
            seen.filter { if case .permission = $0 { return true } else { return false } }.count,
            1,
            "one permission is one notification, however many times it is replayed"
        )
    }

    /// The case a phone actually hits: the agent asked for permission while
    /// the app was away, and the transcript is opened afterwards. Hydration
    /// returns a task that is `waiting` but not what it is waiting on — that
    /// lives in the runtime journal the store has been reading all along.
    func testAPromptSurvivesTheTranscriptBeingClosedAndReopened() async throws {
        let store = try await connect()
        let model = try await store.open(demoSession)
        try await store.send(prompt: "Fix the limiter", to: model)
        try await waitUntil("the scripted permission arrives") { model.pendingPermission != nil }
        let requestId = try XCTUnwrap(model.pendingPermission?.requestId)

        store.close(demoSession)
        let reopened = try await store.open(demoSession)
        XCTAssertEqual(reopened.pendingPermission?.requestId, requestId)

        let allow = try XCTUnwrap(reopened.pendingPermission?.options.first { $0.allow })
        try await store.respond(reopened, requestId: requestId, optionId: allow.id)
        XCTAssertNil(store.pendingInteractions[self.demoSession])
    }

    // MARK: - Drafts

    func testDraftsRoundTripThroughTheDaemon() async throws {
        let store = try await connect()
        let key = ComposerDraftKey.session(sessionId: demoSession)
        store.setDraft(ComposerDraft(text: "half a thought"), for: key)

        // The write is debounced, so the assertion is on what it settles to.
        try await waitUntil("the keyed draft write goes out") { store.draftWrites.isEmpty }
        XCTAssertEqual(store.draft(for: key).text, "half a thought")

        // A remote load must not wipe what is still being typed here.
        store.setDraft(ComposerDraft(text: "still typing"), for: key)
        store.refreshComposerDrafts()
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(store.draft(for: key).text, "still typing")
    }

    func testADraftMovesWithATaskThatChangesProject() async throws {
        let store = try await connect()
        let first = try XCTUnwrap(store.projects.first)
        let second = try XCTUnwrap(store.projects.dropFirst().first)
        let source = ComposerDraftKey.newSession(projectId: first.id)
        let destination = ComposerDraftKey.newSession(projectId: second.id)

        store.setDraft(ComposerDraft(text: "carry me"), for: source)
        store.moveDraft(from: source, to: destination)
        XCTAssertEqual(store.draft(for: destination).text, "carry me")
        XCTAssertTrue(store.draft(for: source).isEmpty)
    }

    // MARK: - Composer sources

    func testTheComposerSourcesLoadFromTheDaemon() async throws {
        let store = try await connect()
        let model = try await store.open(demoSession)
        store.refreshComposerSources(for: model.session)

        try await waitUntil("the model probe lands") { store.probes[.claude] != nil }
        try await waitUntil("the file list lands") { !store.files(for: model.session).isEmpty }
        try await waitUntil("the branch snapshot lands") {
            store.branchSnapshot(for: model.session) != nil
        }
        try await waitUntil("the slash commands land") {
            store.commands(for: model.session).contains { $0.scope == .skill }
        }

        let probe = try XCTUnwrap(store.probes[.claude])
        XCTAssertFalse(probe.models.isEmpty, "the model picker has something to pick from")
        let snapshot = try XCTUnwrap(store.branchSnapshot(for: model.session))
        XCTAssertNotNil(snapshot.displayBranch)
    }

    func testBrowsingTheDaemonFilesystemAndAddingWhatWasFound() async throws {
        let store = try await connect()
        let home = try await store.browseDirectory(path: nil)
        XCTAssertFalse(home.entries.isEmpty)
        let directory = try XCTUnwrap(home.entries.first(where: \.isDir))

        let deeper = try await store.browseDirectory(path: directory.absolutePath)
        XCTAssertEqual(deeper.path, directory.absolutePath)
        XCTAssertNotNil(deeper.parent, "a browser needs somewhere to go back to")

        // Adding a project the daemon already knows returns the one it has
        // rather than a duplicate row.
        let existing = try XCTUnwrap(store.projects.first)
        let added = try await store.addProject(path: existing.path)
        XCTAssertEqual(added.id, existing.id)
    }

    func testAttachingAnImagePutsItInTheDaemonsBlobStore() async throws {
        let store = try await connect()
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        let attachment = try await store.attachImage(
            data: png, mimeType: "image/png", name: "shot.png")

        XCTAssertTrue(attachment.isImage)
        XCTAssertEqual(attachment.mention, attachment.path)
        XCTAssertNotNil(attachment.blobReference)
        let readBack = try await store.attachmentData(attachment)
        XCTAssertEqual(readBack, png)
    }

    func testAttachingADaemonPathMentionsItByPath() async throws {
        let store = try await connect()
        let model = try await store.open(demoSession)
        let cwd = try XCTUnwrap(store.cwd(for: model.session))
        store.refreshProjectFiles(cwd: cwd)
        try await waitUntil("the file list lands") { !store.files(for: model.session).isEmpty }

        // The demo can only import what it actually holds bytes for, which is
        // its workspace images — the same constraint a real daemon has for a
        // path outside the project.
        let file = try XCTUnwrap(store.files(for: model.session).first {
            !$0.isDir && MessageAttachment.isImageName($0.path)
        })
        let attachment = try await store.attachDaemonPath("\(cwd)/\(file.path)")
        XCTAssertFalse(attachment.isDir)
        XCTAssertEqual(attachment.mention, "\(cwd)/\(file.path)")
        XCTAssertTrue(attachment.isImage)
    }

    // MARK: - Session options

    func testChangingTheModelPersistsAndRetunesALiveRuntime() async throws {
        let store = try await connect()
        let model = try newDraft(in: store)
        try await store.send(prompt: "Start the showcase", to: model)
        try await waitUntil("the runtime is up") { model.runtimeId != nil }

        var session = model.currentProjection
        session.model = "claude-opus-5"
        session.runtimeMode = .ask
        try await store.saveSession(session)

        XCTAssertEqual(model.currentProjection.model, "claude-opus-5")
        XCTAssertEqual(model.currentProjection.runtimeMode, .ask)
        // `applyOptions` succeeded, so the runtime is kept rather than closed.
        XCTAssertNotNil(model.runtimeId)
    }
}
