import UIKit
import XCTest

/// Run against the local Demo Daemon, whose audit task echoes long prompts.
@MainActor
final class WorkingIndicatorUITests: XCTestCase {
    func testActiveTimerAndBackgroundResume() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launch()
        defer {
            if app.buttons["Stop"].exists { app.buttons["Stop"].tap() }
        }
        let demo = app.buttons["Try the demo"]
        if demo.waitForExistence(timeout: 10) { demo.tap() }
        XCTAssertTrue(app.descendants(matching: .any)["transcript-scroll"].waitForExistence(timeout: 30))
        app.buttons["Tasks"].tap()
        let task = app.descendants(matching: .any)["session-5eed0000-0000-0000-0000-000000020003"]
        XCTAssertTrue(task.waitForExistence(timeout: 10))
        task.tap()
        if app.buttons["Stop"].exists { app.buttons["Stop"].tap() }

        let composer = app.textViews.matching(NSPredicate(format: "label BEGINSWITH %@", "Ask Shidou")).firstMatch
        XCTAssertTrue(composer.waitForExistence(timeout: 10))
        UIPasteboard.general.string = String(repeating: "Explain the refill rate and burst allowance. ", count: 400)
        composer.tap()
        composer.press(forDuration: 1.2)
        let paste = app.menuItems["Paste"]
        XCTAssertTrue(paste.waitForExistence(timeout: 5))
        paste.tap()
        if app.buttons["Allow Paste"].waitForExistence(timeout: 1) { app.buttons["Allow Paste"].tap() }
        app.buttons["Send"].tap()
        let working = app.descendants(matching: .any)["working-indicator"].firstMatch
        XCTAssertTrue(working.waitForExistence(timeout: 10))
        let jump = app.buttons["Scroll to bottom"]
        if jump.exists { jump.tap() }

        var samples: [Int] = []
        let deadline = Date().addingTimeInterval(6)
        while Date() < deadline {
            let seconds = try elapsed(working)
            if samples.last != seconds { samples.append(seconds) }
            usleep(100_000)
        }
        print("Working timer samples: \(samples)")
        XCTAssertGreaterThanOrEqual(samples.count, 5)
        for pair in zip(samples, samples.dropFirst()) {
            XCTAssertEqual(pair.1, pair.0 + 1, "the timer must not skip seconds")
        }

        // Pixel-level spinner assertions live in WorkingRowTests, where
        // streaming cannot move the row between measuring and capturing it.
        let before = try elapsed(working)
        let leftAt = Date()
        XCUIDevice.shared.press(.home)
        sleep(3)
        app.activate()
        XCTAssertTrue(working.waitForExistence(timeout: 10))
        let after = try elapsed(working)
        XCTAssertEqual(Double(after - before), Date().timeIntervalSince(leftAt), accuracy: 2)
        app.buttons["Stop"].tap()
        XCTAssertTrue(working.waitForNonExistence(timeout: 5), "the indicator must leave when the turn ends")
    }

    private func elapsed(_ row: XCUIElement) throws -> Int {
        let value = row.label.split(separator: " ").compactMap { Int($0) }.first
        return try XCTUnwrap(value, "expected a working duration, got \(row.label)")
    }
}
