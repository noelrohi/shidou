import Observation
import ShidouProtocol
import SwiftUI
import XCTest
@testable import Shidou

@MainActor
final class WorkingRowTests: XCTestCase {
    func testElapsedUsesTurnTimestampAcrossUpdatesAndResume() {
        for (now, expected) in [(99.0, 0), (100.0, 0), (101.0, 1), (103.0, 3), (165.9, 65)] {
            XCTAssertEqual(WorkingRow.elapsedSeconds(
                startedAt: 100, now: Date(timeIntervalSince1970: now)
            ), expected)
        }
    }

    func testHostedClockSpinnerAndToolRows() async throws {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 800))
        let fixture = Fixture()
        let controller = UIHostingController(rootView: FixtureView(fixture: fixture))
        window.windowScene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        try await Task.sleep(for: .seconds(1))
        window.layoutIfNeeded()
        let indicators = descendants(window).compactMap { $0 as? UIActivityIndicatorView }
        XCTAssertEqual(indicators.count, 1, "only the main working row spins, not running or completed tools")
        let spinner = try XCTUnwrap(indicators.first)
        XCTAssertNotNil(spinner.window)
        XCTAssertTrue(spinner.isAnimating)
        let activitySnapshot = XCTAttachment(image: capture(window, rect: window.bounds))
        activitySnapshot.name = "Active working row and spinner-free tools"
        activitySnapshot.lifetime = .keepAlways
        add(activitySnapshot)
        let first = capture(window, rect: spinner.convert(spinner.bounds, to: window))
        try await Task.sleep(for: .milliseconds(270))
        let second = capture(window, rect: spinner.convert(spinner.bounds, to: window))
        XCTAssertNotEqual(first.pngData(), second.pngData(), "the visible spinner must change, not just report isAnimating")
        for _ in 0..<5 {
            fixture.revision += 1
            controller.rootView = FixtureView(fixture: fixture)
            window.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(120))
        }
        let updatedSpinner = try XCTUnwrap(descendants(window).compactMap { $0 as? UIActivityIndicatorView }.first)
        XCTAssertTrue(updatedSpinner.isAnimating)
        let afterUpdate = capture(window, rect: updatedSpinner.convert(updatedSpinner.bounds, to: window))
        try await Task.sleep(for: .milliseconds(270))
        XCTAssertNotEqual(afterUpdate.pngData(), capture(window, rect: updatedSpinner.convert(updatedSpinner.bounds, to: window)).pngData())

        // With no fixture updates or agent events, only the row's clock can
        // change the text. Exclude the spinner from these captures.
        let spinnerRect = updatedSpinner.convert(updatedSpinner.bounds, to: window)
        let labelRect = CGRect(x: spinnerRect.maxX + 8, y: spinnerRect.minY - 4, width: 220, height: 24)
        var previous = capture(window, rect: labelRect).pngData()
        for _ in 0..<3 {
            try await Task.sleep(for: .seconds(1))
            let current = capture(window, rect: labelRect).pngData()
            XCTAssertNotEqual(previous, current, "elapsed text must update every second without incoming events")
            previous = current
        }
        fixture.isWaiting = true
        controller.rootView = FixtureView(fixture: fixture)
        window.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertFalse(updatedSpinner.isAnimating)
        XCTAssertTrue(descendants(window).compactMap { $0 as? UIActivityIndicatorView }.isEmpty,
                      "waiting and tool rows have no spinner")
        fixture.isWaiting = false
        controller.rootView = FixtureView(fixture: fixture)
        window.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(300))
        let resumedSpinner = try XCTUnwrap(descendants(window).compactMap { $0 as? UIActivityIndicatorView }.first)
        XCTAssertTrue(resumedSpinner.isAnimating)
        fixture.isRunning = false
        controller.rootView = FixtureView(fixture: fixture)
        window.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(300))
        let table = try XCTUnwrap(descendants(window).compactMap { $0 as? UITableView }.first)
        XCTAssertEqual(table.numberOfRows(inSection: 0), 1)
        XCTAssertTrue(table.visibleCells.flatMap(descendants).compactMap { $0 as? UIActivityIndicatorView }.isEmpty,
                      "ending a turn leaves only tool rows, with no visible spinner")
    }

    private func descendants(_ view: UIView) -> [UIView] {
        [view] + view.subviews.flatMap(descendants)
    }

    private func capture(_ window: UIWindow, rect: CGRect) -> UIImage {
        UIGraphicsImageRenderer(size: rect.size).image { context in
            context.cgContext.translateBy(x: -rect.minX, y: -rect.minY)
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
    }

    private struct Row: Identifiable {
        let id: String
        let revision: Int
    }

    @MainActor @Observable
    final class Fixture {
        var revision = 0
        var isWaiting = false
        var isRunning = true
        let block = TranscriptBlock(afterMessage: 0, turnId: nil, activities: [
            ActivityItem(kind: .command, title: "sleep 30", complete: false),
            ActivityItem(kind: .fileRead, title: "Read file", complete: true),
            ActivityItem(kind: .command, title: "Failed command", failed: true, complete: true),
        ])
        let startedAt = UInt64(Date().timeIntervalSince1970)
        let scrollState = TranscriptScrollState()
    }

    private struct FixtureView: View {
        let fixture: Fixture
        var body: some View {
            let isWaiting = fixture.isWaiting
            return TranscriptList(
                rows: [Row(id: "tools", revision: fixture.revision)]
                    + (fixture.isRunning ? [Row(id: "working", revision: fixture.revision)] : []),
                scrollState: fixture.scrollState, request: nil, submittedMessageID: nil
            ) { row in
                if row.id == "working" {
                    WorkingRow(startedAt: fixture.startedAt, isWaiting: isWaiting)
                } else {
                    ActivityGroupRow(block: fixture.block, isLive: fixture.isRunning, expandedActivities: .constant([]))
                }
            }
        }
    }
}
