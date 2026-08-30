import XCTest

/// Regression coverage for the transcript's jump-to-tail control.
@MainActor
final class ScrollToBottomProbeUITests: XCTestCase {
    func testButtonAppearsAwayFromTailAndReturnsToBottom() {
        let app = XCUIApplication()
        app.launch()
        dismissSystemAlerts()

        let tryTheDemo = app.buttons["Try the demo"]
        if tryTheDemo.waitForExistence(timeout: 10) {
            tryTheDemo.tap()
        }

        let tasks = app.buttons["Tasks"]
        if tasks.waitForExistence(timeout: 15) {
            tasks.tap()
        }

        let row = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH %@", "Rate limiting")
        ).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 30), "task row should exist")
        for _ in 0..<50 where !row.isHittable {
            usleep(100_000)
        }
        row.tap()

        let transcript = app.scrollViews["transcript-scroll"]
        XCTAssertTrue(transcript.waitForExistence(timeout: 30), "transcript should render")

        let field = app.textViews.matching(
            NSPredicate(format: "label BEGINSWITH %@", "Ask Shidou")
        ).firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 10), "composer should exist")
        field.tap()
        let paragraph = "Please explain where the rate limiter lives, how its bucket refills, what burst allowance it permits, and what happens when the bucket runs dry. "
        field.typeText(String(repeating: paragraph, count: 4))
        app.buttons["Send"].tap()

        let jump = app.buttons["Scroll to bottom"]
        for _ in 0..<6 where !jump.exists {
            transcript.swipeDown(velocity: .slow)
            usleep(300_000)
        }
        XCTAssertTrue(
            jump.waitForExistence(timeout: 3),
            "scrolling away should surface the jump button"
        )

        jump.tap()
        XCTAssertTrue(
            jump.waitForNonExistence(timeout: 3),
            "the jump button should hide after returning to the tail"
        )
    }

    private func dismissSystemAlerts() {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        for _ in 0..<10 {
            let allow = springboard.buttons["Allow"]
            if allow.exists { allow.tap() }
            let deny = springboard.buttons["Don't Allow"]
            if deny.exists { deny.tap() }
            usleep(200_000)
        }
    }
}
