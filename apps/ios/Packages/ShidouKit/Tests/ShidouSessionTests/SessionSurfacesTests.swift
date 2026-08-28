import Foundation
import ShidouClient
import ShidouProtocol
import XCTest

@testable import ShidouSession

/// The read-only surfaces, settings, skills, usage and git, driven against a
/// real `shidou-demo` over the real wire — the same rule the earlier slices
/// followed. Every command this slice added has a consumer here, so a wire
/// shape that decodes in a unit test but not against the daemon is caught by
/// the daemon.
@MainActor
final class SessionSurfacesTests: XCTestCase {
    private let demoSession = UUID(uuidString: "5eed0000-0000-0000-0000-000000020001")!
    private let workspaceRoot = "/Users/demo/Developer/shidou"

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

    // MARK: - Files

    func testTheFileTreeListsAndExpandsThroughTheDaemon() async throws {
        let store = try await connect()
        let surfaces = store.surfaces(for: workspaceRoot)

        surfaces.loadTree()
        try await waitUntil("the tree loads") { surfaces.hasLoadedTree }
        XCTAssertNil(surfaces.treeError)
        XCTAssertTrue(surfaces.tree.contains { $0.relativePath == "src" && $0.isDir })
        XCTAssertFalse(
            surfaces.tree.contains { $0.relativePath == "src/limiter.rs" },
            "a collapsed directory does not list its children"
        )

        let src = try XCTUnwrap(surfaces.tree.first { $0.relativePath == "src" })
        surfaces.toggle(src)
        try await waitUntil("the expanded tree lands") {
            surfaces.tree.contains { $0.relativePath == "src/limiter.rs" }
        }
        let changed = try XCTUnwrap(surfaces.tree.first { $0.relativePath == "src/limiter.rs" })
        XCTAssertEqual(changed.status, .modified, "the tree carries working-copy status")
        XCTAssertTrue(surfaces.isExpanded(src))
    }

    func testReadingAFileAndFollowingATranscriptLinkToALine() async throws {
        let store = try await connect()
        let surfaces = store.surfaces(for: workspaceRoot)

        // The shape a transcript file link produces.
        let route = TranscriptLinks.route(
            target: "/Users/demo/Developer/shidou/src/limiter.rs:42", workspace: workspaceRoot)
        guard case .projectFile(let path, let line) = route else {
            return XCTFail("expected a project-file route")
        }
        surfaces.openFile(WorkspaceRelativePath(path), focusLine: line)
        try await waitUntil("the file loads") { surfaces.openFile?.content != nil }

        let file = try XCTUnwrap(surfaces.openFile)
        XCTAssertEqual(file.relativePath, "src/limiter.rs")
        XCTAssertEqual(file.focusLine, 42)
        XCTAssertNil(file.error)
        XCTAssertTrue(file.content?.contains("REFILL_PER_SECOND") ?? false)
    }

    /// A read that fails has to say so on the file, not silently show the
    /// previous one.
    func testAMissingFileReportsItsError() async throws {
        let store = try await connect()
        let surfaces = store.surfaces(for: workspaceRoot)
        surfaces.openFile("src/nope.rs")
        try await waitUntil("the read fails") { surfaces.openFile?.error != nil }
        XCTAssertNil(surfaces.openFile?.content)
    }

    // MARK: - Changes

    func testTheReviewDiffParsesIntoFilesAndHunks() async throws {
        let store = try await connect()
        let surfaces = store.surfaces(for: workspaceRoot)

        surfaces.loadDiff()
        try await waitUntil("the diff loads") { surfaces.hasLoadedDiff }
        XCTAssertNil(surfaces.diffError)
        XCTAssertEqual(surfaces.diffFiles.map(\.path), ["src/limiter.rs"])
        // The demo's own constants for the one edited file.
        XCTAssertEqual(surfaces.diffAdditions, 11)
        XCTAssertEqual(surfaces.diffDeletions, 6)
        XCTAssertTrue(surfaces.diffIsComplete)
        XCTAssertFalse(surfaces.diffFiles[0].hunks.isEmpty)
    }

    func testSwitchingTheDiffSourceRefetches() async throws {
        let store = try await connect()
        let surfaces = store.surfaces(for: workspaceRoot)
        surfaces.loadDiff()
        try await waitUntil("the diff loads") { surfaces.hasLoadedDiff }

        surfaces.selectDiffSource(.staged)
        try await waitUntil("the staged diff loads") {
            surfaces.hasLoadedDiff && surfaces.diffSource == .staged
        }
        XCTAssertNil(surfaces.diffError)
    }

    // MARK: - Visuals

    func testTheGalleryFindsTheWorkspacesImagesAndReadsTheirBytes() async throws {
        let store = try await connect()
        let surfaces = store.surfaces(for: workspaceRoot)

        surfaces.loadImages()
        try await waitUntil("the gallery loads") { surfaces.hasLoadedImages }
        XCTAssertEqual(
            surfaces.images.map(\.path),
            ["assets/latency-after.png", "assets/latency-before.png"]
        )

        let first = try XCTUnwrap(surfaces.images.first)
        let imagePath = WorkspaceRelativePath(first.path)
        surfaces.loadImage(imagePath)
        try await waitUntil("the image bytes arrive") {
            surfaces.imageBytes(for: imagePath) != nil
        }
        let bytes = try XCTUnwrap(surfaces.imageBytes(for: imagePath))
        XCTAssertEqual([UInt8](bytes.prefix(4)), [0x89, 0x50, 0x4E, 0x47], "a real PNG")
    }

    /// The bytes cache is observed, so this proves a write invalidates — a
    /// thumbnail must not wait for an unrelated redraw to see its image.
    func testCachingImageBytesNotifiesObservers() async throws {
        let store = try await connect()
        let surfaces = store.surfaces(for: workspaceRoot)

        surfaces.loadImages()
        try await waitUntil("the gallery loads") { surfaces.hasLoadedImages }
        let first = try XCTUnwrap(surfaces.images.first)
        let imagePath = WorkspaceRelativePath(first.path)

        let notified = expectation(description: "observers see the bytes land")
        withObservationTracking {
            _ = surfaces.imageBytes(for: imagePath)
        } onChange: {
            notified.fulfill()
        }

        surfaces.loadImage(imagePath)
        try await waitUntil("the image bytes arrive") { surfaces.imageBytes(for: imagePath) != nil }
        await fulfillment(of: [notified], timeout: 5)
    }

    // MARK: - Background work

    func testTheScriptedTurnFillsTheBackgroundWorkLedger() async throws {
        let store = try await connect()
        let model = try await store.open(demoSession)
        try await playShowcase(store, model)

        let watcher = try XCTUnwrap(
            model.backgroundWork.items.first { $0.key.kind == .process })
        XCTAssertEqual(watcher.title, "cargo watch")
        XCTAssertEqual(watcher.status, .completed)
        XCTAssertTrue(
            model.backgroundWork.items.contains { $0.key.kind == .subagent },
            "a settled subagent stays in the panel"
        )
    }

    /// The daemon answers `refreshBackgroundWork` with an authoritative
    /// snapshot of what is still live. The demo's is empty, and nothing the
    /// showcase left behind is still live — so a reconcile has to leave the
    /// settled rows alone rather than emptying the panel.
    func testRefreshReconcilesAgainstTheDaemonWithoutErasingSettledWork() async throws {
        let store = try await connect()
        let model = try await store.open(demoSession)
        try await playShowcase(store, model)
        let before = model.backgroundWork.items.count

        try await store.refreshBackgroundWork(demoSession)
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(model.backgroundWork.items.count, before)
        XCTAssertEqual(model.backgroundWork.liveCount, 0)
    }

    /// Runs the scripted showcase to its end, answering the two prompts it
    /// blocks on. The background-work beats sit after both of them, so
    /// nothing here is reachable without playing the whole thing.
    private func playShowcase(_ store: SessionStore, _ model: SessionRuntimeModel) async throws {
        try await store.send(prompt: "Fix the limiter", to: model)

        try await waitUntil("the scripted permission arrives") { model.pendingPermission != nil }
        let permission = try XCTUnwrap(model.pendingPermission)
        let allow = try XCTUnwrap(permission.options.first { $0.allow })
        try await store.respond(model, requestId: permission.requestId, optionId: allow.id)

        try await waitUntil("the question form arrives") { model.pendingUserInput != nil }
        let question = try XCTUnwrap(model.pendingUserInput)
        try await store.respondUserInput(
            model,
            requestId: question.requestId,
            answers: question.questions.map {
                UserInputAnswer(questionId: $0.id, answers: [$0.options.first?.label ?? "yes"])
            }
        )

        try await waitUntil("the turn finishes") { !model.session.status.isBusy }
    }

    // MARK: - Git

    func testInspectCommitAndTheGeneratedMessage() async throws {
        let store = try await connect()
        let snapshot = try await store.inspectCommit(cwd: workspaceRoot)
        XCTAssertEqual(snapshot.branch, "demo/rate-limiter")
        XCTAssertTrue(snapshot.hasUnstaged)
        XCTAssertTrue(snapshot.canPush)
        XCTAssertEqual(store.workspaces[workspaceRoot]?.branch, "demo/rate-limiter")

        let session = try XCTUnwrap(store.sessions.first { $0.id == self.demoSession })
        let message = try await store.generateCommitMessage(
            cwd: workspaceRoot, session: session, includeUnstaged: true)
        XCTAssertTrue(message.hasPrefix("fix(limiter):"))
    }

    /// The demo refuses to commit or push, on purpose: a reviewer who taps
    /// Commit should learn the demo is read-only rather than watch a button do
    /// nothing. The app's job is to surface that refusal.
    func testTheDemoRefusesToCommitAndSaysWhy() async throws {
        let store = try await connect()
        do {
            _ = try await store.commit(
                cwd: workspaceRoot, message: "nope", includeUnstaged: true, push: false)
            XCTFail("the demo has no repository to commit to")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("commit"))
        }
    }

    // MARK: - Settings, skills, usage

    func testSettingsRoundTripWithoutLosingKeysThePhoneNeverShows() async throws {
        let store = try await connect()
        var settings = try await store.loadSettings()
        XCTAssertTrue(settings.conventionalCommitMessages, "the demo's own fixture")

        settings.setEnabled(false, for: .codex)
        settings.setBinaryOverride("/opt/demo/claude", for: .claude)
        try await store.updateSettings(settings)

        XCTAssertEqual(store.settings?.binaryOverride(for: .claude), "/opt/demo/claude")
        XCTAssertFalse(store.settings?.isEnabled(.codex) ?? true)
        XCTAssertTrue(store.probes.isEmpty, "a changed override invalidates the probes")
    }

    func testTheSkillsCatalogLoadsAndCanBeToggled() async throws {
        let store = try await connect()
        let catalog = try await store.loadSkills()
        XCTAssertEqual(catalog.skills.map(\.name), ["tdd", "code-review", "release-notes"])
        XCTAssertEqual(catalog.disabledCount, 1)

        let disabled = try XCTUnwrap(catalog.skills.first { !$0.enabled })
        XCTAssertEqual(disabled.scope, .project)
        XCTAssertEqual(disabled.project, "shidou")
        try await store.setSkillsEnabled(dirs: disabled.dirs, enabled: true)
    }

    /// Trashing is the one skills command the demo refuses, so the app has to
    /// carry the error rather than pretend the row is gone.
    func testTrashingASkillIsRefusedByTheDemo() async throws {
        let store = try await connect()
        let catalog = try await store.loadSkills()
        let skill = try XCTUnwrap(catalog.skills.first)
        do {
            try await store.trashSkills(dirs: skill.dirs)
            XCTFail("the demo cannot delete skills")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("skills"))
        }
    }

    func testUsageHistoryLoadsForEveryWindowChoice() async throws {
        let store = try await connect()
        for window in UsageWindow.choices {
            let history = try await store.loadUsageHistory(window: window)
            XCTAssertEqual(history.window, window)
            XCTAssertFalse(history.daily.isEmpty)
            XCTAssertTrue(history.sinceDay <= history.untilDay)
            XCTAssertFalse(history.providers.isEmpty)
        }

        let monthly = try await store.loadUsageHistory(window: .monthly)
        XCTAssertFalse(monthly.months.isEmpty)
        XCTAssertFalse(monthly.projects.isEmpty)
    }
}
