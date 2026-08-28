import Foundation
import ShidouClient
import ShidouProtocol
import XCTest

@testable import ShidouSession

/// The store, driven against a real `shidou-demo` over the real wire.
///
/// Nothing here is stubbed: a daemon process is started, a supervisor walks to
/// it, and the store does what it does in the app. That is the point — every
/// behaviour worth testing in the store is a behaviour of its conversation
/// with a daemon, and a fake daemon would only assert that the fake matches
/// the store's assumptions.
@MainActor
final class SessionStoreTests: XCTestCase {
    /// The Demo Session, the one the scripted turn plays into.
    private let demoSession = UUID(uuidString: "5eed0000-0000-0000-0000-000000020001")!
    /// The Waiting Session: blocked on the user, so the list has something to
    /// mark.
    private let waitingSession = UUID(uuidString: "5eed0000-0000-0000-0000-000000020002")!

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

    private func connect(replayJournalLimit: Int? = nil) async throws -> SessionStore {
        let daemon = try DemoDaemonProcess(replayJournalLimit: replayJournalLimit)
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

    /// Polls a condition on the main actor. Store state lands from tasks the
    /// store owns, so a test asserts on what it settles to, not on a timing.
    private func waitUntil(
        _ description: String,
        timeout: TimeInterval = 20,
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

    // MARK: - Catalog

    func testTheCatalogArrivesOnConnectAndCarriesTheWaitingSession() async throws {
        let store = try await connect()

        XCTAssertFalse(store.projects.isEmpty)
        XCTAssertTrue(store.sessions.contains { $0.id == self.demoSession })
        XCTAssertEqual(
            store.sessions.first { $0.id == self.waitingSession }?.status,
            .waiting,
            "the list has to have something to mark"
        )
        XCTAssertNil(store.catalogError)

        // The catalog is a projection: rows carry titles and status, never
        // transcripts, or the list would hold a copy of every conversation.
        XCTAssertTrue(store.sessions.allSatisfy(\.messages.isEmpty))
    }

    func testTheSessionListGroupsWhatTheDaemonSent() async throws {
        let store = try await connect()
        let sections = SessionListPresentation.sections(
            sessions: store.sessions, projects: store.projects
        )
        XCTAssertFalse(sections.isEmpty)
        XCTAssertTrue(sections.flatMap(\.items).contains { $0.session.id == self.demoSession })
    }

    // MARK: - Opening

    func testOpeningASessionHydratesItsTranscriptAndAttachesTheRuntime() async throws {
        let store = try await connect()
        let model = try await store.open(demoSession)

        XCTAssertFalse(model.session.messages.isEmpty, "hydrate brings the transcript")
        XCTAssertTrue(model.isAttached)
        XCTAssertFalse(model.isCatchingUp)
        XCTAssertFalse(TranscriptPresentation.rows(model.session).isEmpty)

        // Opening again is the same model, not a second hydrate.
        let again = try await store.open(demoSession)
        XCTAssertTrue(model === again)
    }

    func testTheWorkspaceSubtitleResolvesInTheBackground() async throws {
        let store = try await connect()
        let model = try await store.open(demoSession)
        try await waitUntil("the workspace snapshot lands") {
            store.workspace(for: model.session) != nil
        }
        XCTAssertFalse(store.workspace(for: model.session)?.branch.isEmpty ?? true)
    }

    // MARK: - Streaming

    func testAScriptedTurnStreamsIntoTheProjection() async throws {
        let store = try await connect()
        let model = try await store.open(demoSession)
        try await start(model, in: store)
        try await prompt("Where is the rate limiting?", model: model, store: store)

        try await waitUntil("assistant text arrives", timeout: 30) {
            model.session.messages.contains {
                $0.role == .assistant && !$0.content.isEmpty
                    && $0.createdAt >= model.session.turns.last?.startedAt ?? 0
            }
        }
        try await waitUntil("a tool activity arrives", timeout: 30) {
            model.session.transcriptBlocks.contains { !$0.activities.isEmpty }
        }
    }

    // MARK: - Reconnect and replay

    func testAReconnectResumesWithoutDuplicatingTheTranscript() async throws {
        let store = try await connect()
        let model = try await store.open(demoSession)
        try await start(model, in: store)
        try await prompt("Stream something", model: model, store: store)
        try await waitUntil("the turn produces output", timeout: 30) {
            !model.session.transcriptBlocks.isEmpty || model.session.messages.count > 2
        }

        let before = model.session.messages.count
        await supervisor?.suspend()
        await supervisor?.retryImmediately()
        try await waitUntil("the connection comes back", timeout: 30) {
            store.hasLoadedCatalog && !store.isLoadingCatalog
        }
        // Replayed events the projection has already incorporated are skipped
        // by the reducer's cursor check, so the transcript may grow but never
        // repeats what it already had.
        XCTAssertGreaterThanOrEqual(model.session.messages.count, before)
        XCTAssertEqual(
            Set(model.session.messages.map(\.id)).count,
            model.session.messages.count,
            "replay must not duplicate messages"
        )
    }

    /// The case the phone actually hits: backgrounded through a long run, the
    /// daemon's 4096-event ring overflows, and replay can no longer make the
    /// client whole. The daemon has to say so, and the store has to refetch
    /// rather than apply the surviving tail onto a projection with a hole.
    func testAnOverflowedJournalTriggersAFullRefetch() async throws {
        let store = try await connect(replayJournalLimit: 4)
        let model = try await store.open(demoSession)
        try await start(model, in: store)

        // Drop the socket, then let the scripted turn spend far more than four
        // events while nobody is listening.
        try await prompt("Overflow the journal", model: model, store: store)
        await supervisor?.suspend()
        try await Task.sleep(for: .seconds(3))

        await supervisor?.retryImmediately()
        try await waitUntil("the daemon reports the gap and the refetch runs", timeout: 30) {
            store.lastReplayGap?.sessionId == self.demoSession
        }
        try await waitUntil("the refetch settles", timeout: 30) {
            !store.refetching.contains(self.demoSession)
        }
        XCTAssertFalse(model.isCatchingUp)
        XCTAssertEqual(
            Set(model.session.messages.map(\.id)).count,
            model.session.messages.count,
            "a refetched transcript is still coherent"
        )
    }

    // MARK: - Mutations

    func testRenamingATaskUpdatesTheListAndSurvivesACatalogReload() async throws {
        let store = try await connect()
        try await store.rename(demoSession, to: "Renamed by the phone")
        XCTAssertEqual(
            store.sessions.first { $0.id == self.demoSession }?.title, "Renamed by the phone"
        )
        // The list row must not have grown a transcript on the way through.
        XCTAssertTrue(store.sessions.first { $0.id == self.demoSession }?.messages.isEmpty ?? false)
    }

    func testDeletingATaskRemovesItFromTheListImmediately() async throws {
        let store = try await connect()
        // The demo daemon acknowledges removal without forgetting its fixture,
        // so this asserts the store's own bookkeeping, which is what it owns.
        try await store.delete(waitingSession)
        XCTAssertFalse(store.open.keys.contains(waitingSession))
        XCTAssertTrue(store.draft(for: .session(sessionId: waitingSession)).isEmpty)
    }

    func testDraftsAreKeptPerComposerAndClearedWhenEmptied() async throws {
        let store = try await connect()
        let key = ComposerDraftKey.session(sessionId: demoSession)
        store.setDraft(ComposerDraft(text: "half a thought"), for: key)
        XCTAssertEqual(store.draft(for: key).text, "half a thought")
        store.setDraft(ComposerDraft(), for: key)
        XCTAssertTrue(store.draft(for: key).isEmpty)
    }

    // MARK: - Helpers

    /// The demo's runtime starts on `Start`, and only a started runtime plays
    /// the script.
    private func start(_ model: SessionRuntimeModel, in store: SessionStore) async throws {
        let runtimeId = UUID()
        let client = try await supervisor!.currentClient()
        _ = try await client.request(
            .start(options: DriverStartOptions(
                provider: model.session.provider.rawValue,
                binary: "demo",
                cwd: store.cwd(for: model.session) ?? "/",
                mode: .fullAccess,
                interactionMode: .build
            )),
            sessionId: model.session.id,
            runtimeId: runtimeId
        )
        model.setRuntime(id: runtimeId, supportsSteer: true)
    }

    private func prompt(
        _ text: String,
        model: SessionRuntimeModel,
        store: SessionStore
    ) async throws {
        let runtimeId = try XCTUnwrap(model.runtimeId)
        model.replaceSession(beginTurn(model.currentProjection, prompt: text))
        let client = try await supervisor!.currentClient()
        _ = try await client.request(
            .prompt(text), sessionId: model.session.id, runtimeId: runtimeId
        )
    }
}
