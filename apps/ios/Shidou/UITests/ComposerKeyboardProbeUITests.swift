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

        let initiallyOpenTranscript = app.scrollViews["transcript-scroll"]
        XCTAssertTrue(initiallyOpenTranscript.waitForExistence(timeout: 30), "a transcript should render")

        app.buttons["Tasks"].tap()
        let rateLimitingTask = app.descendants(matching: .any)[
            "session-5eed0000-0000-0000-0000-000000020001"
        ]
        XCTAssertTrue(rateLimitingTask.waitForExistence(timeout: 10), "demo task should exist")
        rateLimitingTask.tap()

        let transcript = app.scrollViews["transcript-scroll"]
        XCTAssertTrue(transcript.waitForExistence(timeout: 10), "selected transcript should render")
        let visibleAnswer = app.staticTexts.matching(
            NSPredicate(format: "label BEGINSWITH %@", "Each client gets a token bucket")
        ).firstMatch
        XCTAssertTrue(visibleAnswer.waitForExistence(timeout: 10), "the transcript tail should render")

        let field = app.textViews.matching(
            NSPredicate(
                format: "label BEGINSWITH %@ OR label BEGINSWITH %@", "Ask Shidou", "Queue a follow-up")
        ).firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 10), "composer should exist")
        field.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5), "keyboard should rise")
        assertVisible(visibleAnswer, above: app.keyboards.firstMatch, "focused")

        field.typeText(String(repeating: "Explain the refill rate.\n", count: 8))
        assertVisible(visibleAnswer, above: app.keyboards.firstMatch, "typing a long prompt")
        app.buttons["Send"].tap()
        sleep(3)
        field.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        let sentPrompt = app.staticTexts.matching(
            NSPredicate(format: "label BEGINSWITH %@", "Explain the refill rate.")
        ).firstMatch
        XCTAssertTrue(sentPrompt.waitForExistence(timeout: 5), "the sent prompt should render")
        assertVisible(
            sentPrompt, above: app.keyboards.firstMatch, "focused after a send",
            fully: false
        )
    }

    func testFocusingComposerPreservesReadingPosition() {
        let app = XCUIApplication()
        app.launch()

        let tryTheDemo = app.buttons["Try the demo"]
        if tryTheDemo.waitForExistence(timeout: 10) { tryTheDemo.tap() }

        let transcript = app.scrollViews["transcript-scroll"]
        XCTAssertTrue(transcript.waitForExistence(timeout: 30), "a transcript should render")
        app.buttons["Tasks"].tap()
        let task = app.descendants(matching: .any)[
            "session-5eed0000-0000-0000-0000-000000020001"
        ]
        XCTAssertTrue(task.waitForExistence(timeout: 10), "demo task should exist")
        task.tap()
        XCTAssertTrue(transcript.waitForExistence(timeout: 10), "selected transcript should render")

        transcript.swipeDown(velocity: .slow)
        let oldPrompt = app.staticTexts["Where does this service do rate limiting?"]
        XCTAssertTrue(oldPrompt.waitForExistence(timeout: 5), "an older row should be visible")

        let field = app.textViews.matching(
            NSPredicate(format: "label BEGINSWITH %@", "Ask Shidou")
        ).firstMatch
        field.tap()
        let keyboard = app.keyboards.firstMatch
        XCTAssertTrue(keyboard.waitForExistence(timeout: 5), "keyboard should rise")
        assertVisible(oldPrompt, above: keyboard, "opening the keyboard while reading")
    }

    /// A known transcript row must sit inside the viewport left above the
    /// keyboard. Querying one stable element avoids racing the whole changing
    /// accessibility tree while the keyboard and stream settle.
    private func assertVisible(
        _ element: XCUIElement,
        above keyboard: XCUIElement,
        _ when: String,
        fully: Bool = true
    ) {
        let deadline = Date().addingTimeInterval(5)
        var frame = element.frame
        while Date() < deadline {
            frame = element.frame
            let keyboardTop = keyboard.frame.minY
            let visible = fully
                ? frame.minY >= 0 && frame.maxY <= keyboardTop
                : frame.maxY > 0 && frame.minY < keyboardTop
            if frame.height > 0 && visible { break }
            usleep(200_000)
        }
        XCTAssertGreaterThan(frame.height, 0, "the transcript row should have height when \(when)")
        if fully {
            XCTAssertGreaterThanOrEqual(
                frame.minY, 0, "the transcript row should remain on screen when \(when)")
            XCTAssertLessThanOrEqual(
                frame.maxY, keyboard.frame.minY,
                "the transcript row should remain above the keyboard when \(when)"
            )
        } else {
            XCTAssertGreaterThan(frame.maxY, 0, "the transcript row should reach the viewport when \(when)")
            XCTAssertLessThan(
                frame.minY, keyboard.frame.minY,
                "the transcript row should not be entirely behind the keyboard when \(when)"
            )
        }
    }
}
