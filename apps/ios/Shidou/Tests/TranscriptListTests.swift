import Observation
import SwiftUI
import XCTest
@testable import Shidou

@MainActor
final class TranscriptListTests: XCTestCase {
    private var window: UIWindow!
    private var fixture: Fixture!
    private var table: UITableView!

    override func tearDown() {
        window?.isHidden = true
        window = nil
        fixture = nil
        table = nil
        super.tearDown()
    }

    func testGrowingTallRowFollowsBottom() async throws {
        try await open()
        let oldHeight = table.contentSize.height
        fixture.grow()
        try await settle { self.table.contentSize.height > oldHeight + 500 && self.atBottom }
        XCTAssertFalse(fixture.scrollState.isAwayFromLatest)
    }

    func testReadingPositionSurvivesGrowthAndJumpResumesFollowing() async throws {
        try await open()
        table.delegate?.scrollViewWillBeginDragging?(table)
        table.setContentOffset(CGPoint(x: 0, y: table.contentOffset.y - 400), animated: false)
        table.delegate?.scrollViewDidEndDragging?(table, willDecelerate: false)
        let readingOffset = table.contentOffset.y
        let oldHeight = table.contentSize.height
        fixture.grow()
        try await settle { self.table.contentSize.height > oldHeight + 500 }
        XCTAssertEqual(table.contentOffset.y, readingOffset, accuracy: 2)
        XCTAssertTrue(fixture.scrollState.isAwayFromLatest)

        fixture.request = TranscriptScrollRequest(target: .bottom)
        try await settle { self.atBottom }
        let resumedHeight = table.contentSize.height
        fixture.grow()
        try await settle { self.table.contentSize.height > resumedHeight + 500 && self.atBottom }
    }

    func testViewportResizeDoesNotCommandScrollToBottom() async throws {
        try await open()
        let readingOffset = table.contentOffset.y
        // Drive the UIKit viewport boundary directly. The UI probes cover
        // SwiftUI's keyboard-to-viewport propagation through the real composer.
        table.frame.size.height = 320
        table.layoutIfNeeded()
        // Give queued hosted-cell updates a chance to run too.
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(table.contentOffset.y, readingOffset, accuracy: 2)
    }

    func testLongHistoryIsVirtualizedAndFindPreservesItsPosition() async throws {
        try await open(historyCount: 200)
        XCTAssertLessThan(table.visibleCells.count, 20)
        fixture.request = TranscriptScrollRequest(target: .find("history-80"))
        try await settle {
            self.table.indexPathsForVisibleRows?.contains { $0.row == 80 } == true
        }
        let target = IndexPath(row: 80, section: 0)
        let distance = table.rectForRow(at: target).minY - table.contentOffset.y
        fixture.grow()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(table.rectForRow(at: target).minY - table.contentOffset.y, distance, accuracy: 2)
        XCTAssertLessThan(table.visibleCells.count, 20)
    }

    private var atBottom: Bool {
        let maximum = max(-table.adjustedContentInset.top,
                          table.contentSize.height - table.bounds.height + table.adjustedContentInset.bottom)
        return abs(table.contentOffset.y - maximum) < 2
    }

    private func open(historyCount: Int = 5) async throws {
        fixture = Fixture(historyCount: historyCount)
        let root = FixtureView(fixture: fixture)
        let controller = UIHostingController(rootView: root)
        window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 800))
        window.rootViewController = controller
        window.makeKeyAndVisible()
        try await settle {
            self.table = self.findTable(in: controller.view)
            return self.table != nil && self.table.numberOfSections > 0
                && self.table.numberOfRows(inSection: 0) == historyCount + 1
                && self.table.contentSize.height > 1_000 && self.atBottom
        }
    }

    private func findTable(in view: UIView) -> UITableView? {
        if let table = view as? UITableView { return table }
        for child in view.subviews {
            if let table = findTable(in: child) { return table }
        }
        return nil
    }

    private func settle(_ predicate: () -> Bool) async throws {
        for _ in 0..<150 {
            window.layoutIfNeeded()
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("Native transcript layout did not settle: bounds=\(String(describing: table?.bounds)), requested height=\(fixture.height)")
        throw CancellationError()
    }
}

private struct FixtureRow: Identifiable {
    let id: String
    var text: String
}

@MainActor @Observable
private final class Fixture {
    var rows: [FixtureRow]
    var request: TranscriptScrollRequest?
    var height: CGFloat = 600
    let scrollState = TranscriptScrollState()

    init(historyCount: Int) {
        rows = (0..<historyCount).map { FixtureRow(id: "history-\($0)", text: "Earlier message \($0)") }
        rows.append(FixtureRow(id: "reply", text: String(repeating: "A streamed reply line.\n", count: 80)))
    }

    func grow() {
        rows[rows.count - 1].text += String(repeating: "Another streamed reply line.\n", count: 40)
    }
}

private struct FixtureView: View {
    let fixture: Fixture

    var body: some View {
        TranscriptList(
            rows: fixture.rows,
            scrollState: fixture.scrollState,
            request: fixture.request,
            submittedMessageID: nil
        ) { row in
            Text(row.text).fixedSize(horizontal: false, vertical: true)
        }
        .frame(width: 390, height: fixture.height)
        .frame(maxHeight: .infinity, alignment: .top)
        .ignoresSafeArea()
    }
}
