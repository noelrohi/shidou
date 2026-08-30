import XCTest

/// Focusing the composer raises the keyboard; the transcript must stay on
/// screen above it rather than being pushed out of the viewport.
@MainActor
final class ComposerKeyboardProbeUITests: XCTestCase {
    func testTranscriptStaysVisibleWhenComposerFocused() {
        let app = XCUIApplication()
        app.launch()

        let tryTheDemo = app.buttons["Try the demo"]
        if tryTheDemo.waitForExistence(timeout: 10) {
            tryTheDemo.tap()
        }

        let transcript = app.scrollViews["transcript-scroll"]
        _ = transcript.waitForExistence(timeout: 15)
        let row = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH %@", "Rate limiting")
        ).firstMatch
        for _ in 0..<3 where !row.isHittable {
            let tasks = app.buttons["Tasks"]
            if tasks.waitForExistence(timeout: 15), tasks.isHittable { tasks.tap() }
            for _ in 0..<10 where !row.isHittable { usleep(100_000) }
        }
        XCTAssertTrue(row.waitForExistence(timeout: 30))
        row.tap()
        XCTAssertTrue(transcript.waitForExistence(timeout: 30), "transcript should render")

        let field = app.textViews.matching(
            NSPredicate(
                format: "label BEGINSWITH %@ OR label BEGINSWITH %@", "Ask Shidou", "Queue a follow-up")
        ).firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 10), "composer should exist")
        field.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5), "keyboard should rise")
        assertTranscriptShowsText(app, transcript: transcript, "focused")

        field.typeText("Explain the refill rate.")
        app.buttons["Send"].tap()
        sleep(3)
        field.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        assertTranscriptShowsText(app, transcript: transcript, "focused after a send")
    }

    /// Some transcript text must sit inside the viewport that is left above
    /// the keyboard — a transcript pushed up and out has none.
    private func assertTranscriptShowsText(
        _ app: XCUIApplication, transcript: XCUIElement, _ when: String
    ) {
        let keyboardTop = app.keyboards.firstMatch.frame.minY
        let deadline = Date().addingTimeInterval(5)
        var visible: [XCUIElement] = []
        while Date() < deadline {
            visible = app.staticTexts.allElementsBoundByIndex.filter {
                let frame = $0.frame
                return !$0.label.isEmpty && frame.minY >= transcript.frame.minY
                    && frame.maxY <= keyboardTop && frame.height > 0
            }
            if !visible.isEmpty { break }
            usleep(200_000)
        }
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "transcript-\(when)"
        shot.lifetime = .keepAlways
        add(shot)
        XCTAssertFalse(visible.isEmpty, "the transcript should still show rows above the keyboard when \(when)")
    }
}
