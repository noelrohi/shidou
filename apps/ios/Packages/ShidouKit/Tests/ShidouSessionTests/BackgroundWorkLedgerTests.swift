import ShidouProtocol
import XCTest

@testable import ShidouSession

/// Port checks for the web client's background-work reducer. The rules that
/// matter are the ones that decide whether something is *still running*, and
/// getting those wrong shows a user a stop button for a finished process or
/// hides a subagent that is still working.
final class BackgroundWorkLedgerTests: XCTestCase {
    private func item(
        _ kind: BackgroundWorkKind = .process,
        _ providerId: String = "bash-1",
        status: BackgroundWorkStatus,
        background: Bool = true,
        canStop: Bool = true,
        title: String = "cargo watch",
        updatedAtMs: UInt64 = 100
    ) -> BackgroundWorkItem {
        BackgroundWorkItem(
            key: BackgroundWorkKey(kind: kind, providerId: providerId),
            title: title,
            startedAtMs: 100,
            updatedAtMs: updatedAtMs,
            background: background,
            canStop: canStop,
            controlId: providerId,
            status: status
        )
    }

    func testUpsertMergesRatherThanReplaces() throws {
        var ledger = BackgroundWorkLedger()
        var first = item(status: .running)
        first.command = "cargo watch -x test"
        ledger.apply(.upsert(first), now: 200)

        var update = item(status: .completed, canStop: false, title: "", updatedAtMs: 300)
        update.exitCode = 0
        ledger.apply(.upsert(update), now: 300)

        XCTAssertEqual(ledger.items.count, 1)
        let merged = try XCTUnwrap(ledger.items.first)
        XCTAssertEqual(merged.title, "cargo watch", "an empty title does not erase the old one")
        XCTAssertEqual(merged.command, "cargo watch -x test")
        XCTAssertEqual(merged.exitCode, 0)
        XCTAssertEqual(merged.status, .completed)
        XCTAssertFalse(merged.canStop, "settled work cannot be stopped")
    }

    /// Foreground work that finished belongs to the transcript, not here.
    func testSettledForegroundWorkIsDropped() {
        var ledger = BackgroundWorkLedger()
        ledger.apply(.upsert(item(status: .running, background: false)), now: 200)
        XCTAssertEqual(ledger.items.count, 1)
        ledger.apply(.upsert(item(status: .completed, background: false)), now: 300)
        XCTAssertTrue(ledger.isEmpty)
    }

    /// A subagent is kept even once it finishes: the panel is where its result
    /// is read, and the turn that spawned it may already be over.
    func testSettledSubagentsAreKept() {
        var ledger = BackgroundWorkLedger()
        ledger.apply(
            .upsert(item(.subagent, "reviewer-1", status: .completed, background: false)), now: 200
        )
        XCTAssertEqual(ledger.items.count, 1)
    }

    func testStopRequestSurvivesALateRunningUpdate() {
        var ledger = BackgroundWorkLedger()
        ledger.apply(.upsert(item(status: .running)), now: 100)
        ledger.markStopping(BackgroundWorkKey(kind: .process, providerId: "bash-1"), now: 200)
        XCTAssertEqual(ledger.items.first?.status, .stopping)

        // The provider had not heard about the stop yet when it sent this.
        ledger.apply(.upsert(item(status: .running, updatedAtMs: 250)), now: 250)
        XCTAssertEqual(ledger.items.first?.status, .stopping)

        ledger.apply(.upsert(item(status: .stopped, canStop: false, updatedAtMs: 300)), now: 300)
        XCTAssertEqual(ledger.items.first?.status, .stopped)
    }

    func testStopFailedPutsTheItemBackToWork() {
        var ledger = BackgroundWorkLedger()
        let key = BackgroundWorkKey(kind: .monitor, providerId: "watch-1")
        ledger.apply(.upsert(item(.monitor, "watch-1", status: .monitoring)), now: 100)
        ledger.markStopping(key, now: 200)
        ledger.apply(.stopFailed(key: key, message: "no such process"), now: 300)

        XCTAssertEqual(ledger.items.first?.status, .monitoring)
        XCTAssertEqual(ledger.items.first?.detail, "no such process")
    }

    /// A reconcile is the authoritative snapshot: live work it omits is work
    /// whose owner is gone.
    func testReconcileMarksMissingLiveWorkLost() {
        var ledger = BackgroundWorkLedger()
        ledger.apply(.upsert(item(status: .running)), now: 100)
        ledger.apply(.upsert(item(.subagent, "reviewer-1", status: .running)), now: 100)

        ledger.apply(.reconcileProcesses([]), now: 400)
        XCTAssertEqual(ledger.item(for: .init(kind: .process, providerId: "bash-1"))?.status, .lost)
        XCTAssertEqual(
            ledger.item(for: .init(kind: .subagent, providerId: "reviewer-1"))?.status,
            .running,
            "a process reconcile says nothing about subagents"
        )

        ledger.apply(.reconcileLive([]), now: 500)
        XCTAssertEqual(
            ledger.item(for: .init(kind: .subagent, providerId: "reviewer-1"))?.status, .lost)
    }

    func testOutputDeltaAccumulatesAndBounds() {
        var ledger = BackgroundWorkLedger()
        var running = item(status: .running)
        running.output = "first\n"
        ledger.apply(.upsert(running), now: 100)
        let key = BackgroundWorkKey(kind: .process, providerId: "bash-1")
        ledger.apply(.outputDelta(key: key, delta: "second\n"), now: 200)
        XCTAssertEqual(ledger.items.first?.output, "first\nsecond\n")
        XCTAssertFalse(ledger.items.first?.outputTruncated ?? true)

        let flood = String(repeating: "x", count: BackgroundWorkLedger.maxOutputCharacters + 10)
        ledger.apply(.outputDelta(key: key, delta: flood), now: 300)
        XCTAssertEqual(
            ledger.items.first?.output?.count, BackgroundWorkLedger.maxOutputCharacters)
        XCTAssertTrue(ledger.items.first?.outputTruncated ?? false)
    }

    func testSettledItemsAreTrimmedButLiveOnesAreNot() {
        var ledger = BackgroundWorkLedger()
        for index in 0..<(BackgroundWorkLedger.maxSettledItems + 5) {
            ledger.apply(
                .upsert(item(.subagent, "agent-\(index)", status: .completed, canStop: false)),
                now: UInt64(index)
            )
        }
        ledger.apply(.upsert(item(status: .running)), now: 999)
        XCTAssertEqual(ledger.items.filter { !$0.status.isLive }.count,
                       BackgroundWorkLedger.maxSettledItems)
        XCTAssertEqual(ledger.liveCount, 1)
        // The oldest settled entries are the ones dropped.
        XCTAssertNil(ledger.item(for: .init(kind: .subagent, providerId: "agent-0")))
    }

    /// A disconnect leaves nothing behind that can still be reached, so a
    /// spinner against it would be a lie.
    func testMarkLostClearsEveryLiveItem() {
        var ledger = BackgroundWorkLedger()
        ledger.apply(.upsert(item(status: .running)), now: 100)
        ledger.apply(.upsert(item(.subagent, "reviewer-1", status: .completed, canStop: false)),
                     now: 100)
        ledger.markLost(now: 500)
        XCTAssertEqual(ledger.item(for: .init(kind: .process, providerId: "bash-1"))?.status, .lost)
        XCTAssertEqual(ledger.item(for: .init(kind: .process, providerId: "bash-1"))?.canStop, false)
        XCTAssertEqual(
            ledger.item(for: .init(kind: .subagent, providerId: "reviewer-1"))?.status, .completed)
    }

    func testOrderedPutsLiveWorkFirst() {
        var ledger = BackgroundWorkLedger()
        ledger.apply(
            .upsert(item(.subagent, "done", status: .completed, canStop: false, updatedAtMs: 900)),
            now: 900)
        ledger.apply(.upsert(item(status: .running, updatedAtMs: 100)), now: 100)
        XCTAssertEqual(ledger.ordered.map(\.key.providerId), ["bash-1", "done"])
    }
}
