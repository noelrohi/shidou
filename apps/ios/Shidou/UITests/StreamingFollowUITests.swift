import UIKit
import XCTest

/// Uses only the local Demo Daemon's audit task. Its canned reply echoes the
/// prompt at 120 four-character chunks/second. Restart the demo between manual
/// comparison runs so old giant echoes do not accumulate in the fixture.
@MainActor
final class StreamingFollowUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launch()
        let demo = app.buttons["Try the demo"]
        if demo.waitForExistence(timeout: 10) { demo.tap() }
        XCTAssertTrue(app.descendants(matching: .any)["transcript-scroll"].waitForExistence(timeout: 30))
        app.buttons["Tasks"].tap()
        let task = app.descendants(matching: .any)[
            "session-5eed0000-0000-0000-0000-000000020003"
        ]
        XCTAssertTrue(task.waitForExistence(timeout: 10))
        task.tap()
        XCTAssertTrue(app.descendants(matching: .any)["transcript-scroll"].waitForExistence(timeout: 10))
        stopTurn()
    }

    override func tearDownWithError() throws {
        stopTurn()
    }

    func testShortPromptFollowsOverflowWithoutJump() {
        let prompt = "Please explain the refill rate, the burst allowance, and how the rate limiter responds when a bucket runs empty. Probe \(UUID().uuidString.prefix(8))."
        composer.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        composer.typeText(prompt)
        app.buttons["Send"].tap()
        let paragraphs = app.staticTexts.matching(
            NSPredicate(format: "label BEGINSWITH %@", "Everything you have seen")
        )
        XCTAssertTrue(paragraphs.firstMatch.waitForExistence(timeout: 8))
        XCTAssertTrue(app.buttons["Stop"].waitForNonExistence(timeout: 5))
        let tail = paragraphs.element(boundBy: paragraphs.count - 1)
        let user = app.staticTexts[prompt]
        let viewportTop = app.navigationBars.firstMatch.frame.maxY
        let viewportBottom = composer.frame.minY
        let frame = tail.frame
        print("Natural follow: user=\(user.frame), tail=\(frame), viewport=\(viewportTop)...\(viewportBottom)")
        capture("Natural following without jump")
        XCTAssertGreaterThan(frame.maxY - user.frame.minY, viewportBottom - viewportTop + 100,
                             "the turn must overflow the reservation by more than the tail threshold")
        XCTAssertLessThanOrEqual(frame.maxY, viewportBottom, "the final reply paragraph must stay above the composer")
        XCTAssertGreaterThan(frame.maxY, viewportTop)
        XCTAssertFalse(jump.exists, "a short submitted prompt must not require a jump after overflow")
    }

    func testGrowingReplyStaysAtTailWithKeyboardAlreadyDismissed() {
        let reply = sendLongEchoWithKeyboardDismissed()
        reachReplyTail(reply)
        let height = reply.frame.height
        let viewportHeight = composer.frame.minY - app.navigationBars.firstMatch.frame.maxY
        sleep(4)
        XCTAssertTrue(app.buttons["Stop"].exists, "the reply must still be streaming")
        XCTAssertGreaterThan(reply.frame.height, height + viewportHeight,
                             "the same assistant paragraph must grow by more than the visible viewport")
        capture("Following a growing reply")
        assertTailVisible(reply)
    }

    func testScrollUpPausesAndJumpResumesWithKeyboardAlreadyDismissed() {
        let reply = sendLongEchoWithKeyboardDismissed()
        reachReplyTail(reply)
        let beforeDrag = reply.frame.minY
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25))
        let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.60))
        start.press(forDuration: 0.1, thenDragTo: end)
        XCTAssertTrue(jump.waitForExistence(timeout: 3))
        let readingFrame = reply.frame
        XCTAssertGreaterThan(readingFrame.minY, beforeDrag + 100,
                             "the gesture must actually move the reply toward older text")
        sleep(2)
        XCTAssertGreaterThan(reply.frame.height, readingFrame.height + 100,
                             "the reply must continue growing while reading")
        XCTAssertEqual(reply.frame.minY, readingFrame.minY, accuracy: 24,
                       "streaming must preserve the reading position")
        XCTAssertTrue(jump.exists)
        capture("Reading above the streaming tail")
        jump.tap()
        let resumedHeight = reply.frame.height
        XCTAssertTrue(app.buttons["Stop"].exists, "the reply must still stream after jumping")
        sleep(2)
        XCTAssertGreaterThan(reply.frame.height, resumedHeight + 100,
                             "jump must resume following while the reply continues growing")
        capture("Jump resumed following")
        assertTailVisible(reply)
        XCTAssertTrue(jump.waitForNonExistence(timeout: 2))
    }

    private var composer: XCUIElement {
        app.textViews.matching(NSPredicate(
            format: "label BEGINSWITH %@ OR label BEGINSWITH %@", "Ask Shidou", "Queue a follow-up"
        )).firstMatch
    }

    private var jump: XCUIElement { app.buttons["Scroll to bottom"] }

    private func sendLongEchoWithKeyboardDismissed() -> XCUIElement {
        let marker = "Scroll probe \(UUID().uuidString.prefix(8)). "
        let sentence = "The bucket refills steadily. Requests consume tokens, and the limiter rejects requests once the bucket is empty. "
        UIPasteboard.general.string = marker + String(repeating: sentence, count: 96)
        composer.tap()
        composer.press(forDuration: 1.2)
        let paste = app.menuItems["Paste"]
        XCTAssertTrue(paste.waitForExistence(timeout: 5))
        paste.tap()
        let allowPaste = app.buttons["Allow Paste"]
        if allowPaste.waitForExistence(timeout: 1) { allowPaste.tap() }
        // A long draft shrinks the visible transcript. Target its top padding,
        // not a fixed screen fraction that can land in the composer or a row control.
        let transcript = app.descendants(matching: .any)["transcript-scroll"]
        let top = max(transcript.frame.minY, app.navigationBars.firstMatch.frame.maxY)
        app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(
            dx: app.frame.width / 2, dy: top - app.frame.minY + 8
        )).tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 5))
        app.buttons["Send"].tap()
        XCTAssertTrue(app.buttons["Stop"].waitForExistence(timeout: 5))
        return app.staticTexts.matching(
            NSPredicate(format: "label BEGINSWITH %@", "You asked: “" + marker)
        ).firstMatch
    }

    private func reachReplyTail(_ reply: XCUIElement) {
        for _ in 0..<4 {
            if jump.exists { jump.tap() }
            if reply.waitForExistence(timeout: 0.5) { break }
        }
        XCTAssertTrue(reply.exists, "the streamed echo must be materialized before measuring")
        print("At start: reply=\(reply.frame), composerTop=\(composer.frame.minY)")
    }

    private func assertTailVisible(_ reply: XCUIElement) {
        let frame = reply.frame
        let bottom = composer.frame.minY
        print("Tail check: reply=\(frame), composerTop=\(bottom)")
        XCTAssertLessThanOrEqual(frame.maxY, bottom, "the last streamed line must stay above the composer")
        XCTAssertGreaterThan(frame.maxY, app.navigationBars.firstMatch.frame.maxY)
    }

    private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func stopTurn() {
        guard let app, app.buttons["Stop"].exists else { return }
        app.buttons["Stop"].tap()
        XCTAssertTrue(app.buttons["Stop"].waitForNonExistence(timeout: 5))
    }
}
