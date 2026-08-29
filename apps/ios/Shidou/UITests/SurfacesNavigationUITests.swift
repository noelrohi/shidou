import UIKit
import XCTest

/// The slice's "Done when" list, driven through the real UI against a local
/// `shidou-demo`.
///
/// The store tests already prove the conversation with the daemon; what they
/// cannot prove is that every surface is *reachable* and renders the scripted
/// content once it is. On this host synthetic clicks land on whichever window
/// has focus, so a UI test is the only way to press a button in the app
/// reliably — and unlike a screenshot pass it stays true on the next change.
@MainActor
final class SurfacesNavigationUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launch()
        try startDemoIfNeeded()
    }

    /// A fresh simulator lands on the pairing screen; a re-run of the suite
    /// finds the demo already saved. Both have to reach the session list.
    private func startDemoIfNeeded() throws {
        let tryTheDemo = app.buttons["Try the demo"]
        if tryTheDemo.waitForExistence(timeout: 10) {
            tryTheDemo.tap()
        }
        reachSessionList(in: app)
    }

    /// The spine opens the most recent task on its own now, so the session
    /// list is one drawer away. "Tasks" is an accessibility label, not a
    /// localized string, so it matches in every locale.
    private func reachSessionList(in application: XCUIApplication) {
        let tasks = application.buttons["Tasks"]
        if tasks.waitForExistence(timeout: 15) {
            tasks.tap()
        }
        let row = self.taskRow(in: application)
        XCTAssertTrue(
            row.waitForExistence(timeout: 30),
            "the session list should arrive — is `shidou-demo` listening on 127.0.0.1:8787?"
        )
        // The drawer is still sliding in when the row first exists; a tap
        // lands on nothing until it settles.
        for _ in 0..<50 where !row.isHittable {
            usleep(100_000)
        }
        XCTAssertTrue(row.isHittable, "the drawer should settle with the rows hittable")
    }

    /// The list row is one accessibility button whose label folds in the
    /// project and the timestamp, so it is matched by prefix rather than by
    /// the title alone.
    private func openTask(_ title: String = "Rate limiting in the public API") {
        taskRow(title).tap()
    }

    /// On iPhone a row is a `NavigationLink` and reads as a button; on iPad the
    /// same row is a selectable `List` cell and reads as a cell. Both fold the
    /// project and the timestamp into one label, so both are matched by prefix.
    private func taskRow(
        _ title: String = "Rate limiting in the public API",
        in application: XCUIApplication? = nil
    ) -> XCUIElement {
        let target: XCUIApplication = application ?? app
        let predicate = NSPredicate(format: "label BEGINSWITH %@", title)
        let button = target.buttons.matching(predicate).firstMatch
        return button.exists ? button : target.cells.containing(predicate).firstMatch
    }

    /// A section row folds its trailing stat into one accessibility label
    /// ("Changes, +11 −6"), so sections with a stat are matched by prefix.
    /// "Files" matches exactly, or it also hits the panel toggle
    /// ("Files and changes") and closes the panel it just opened.
    private func section(_ name: String) -> XCUIElement {
        let predicate = NSPredicate(
            format: "label == %@ OR label BEGINSWITH %@", name, name + ",")
        return app.buttons.matching(predicate).firstMatch
    }

    /// The drawer keeps an offscreen copy of its toolbar controls in the
    /// accessibility tree, so a plain label query can return a ghost that
    /// cannot be tapped. The hittable one is the real control.
    private func hittableButton(
        _ label: String,
        in application: XCUIApplication? = nil
    ) -> XCUIElement {
        let target: XCUIApplication = application ?? app
        let buttons = target.buttons.matching(NSPredicate(format: "label == %@", label))
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            if let hit = buttons.allElementsBoundByIndex.first(where: { $0.isHittable }) {
                return hit
            }
            usleep(100_000)
        }
        return buttons.firstMatch
    }

    private func openPanel() {
        openTask()
        let panel = app.buttons["Files and changes"]
        XCTAssertTrue(panel.waitForExistence(timeout: 15))
        panel.tap()
        XCTAssertTrue(app.staticTexts["Files"].waitForExistence(timeout: 10))
    }

    func testTheSurfacesSheetReachesEverySection() {
        openPanel()
        for section in ["Files", "Changes", "Visuals", "Background Work"] {
            XCTAssertTrue(
                self.section(section).exists, "\(section) should be a row in the sheet")
        }
    }

    func testFilesBrowsesTheTreeAndReadsAFile() {
        openPanel()
        section("Files").tap()
        XCTAssertTrue(app.staticTexts["Cargo.toml"].waitForExistence(timeout: 15))

        // A directory expands in place; a file pushes the reader.
        app.staticTexts["src"].tap()
        XCTAssertTrue(app.staticTexts["limiter.rs"].waitForExistence(timeout: 15))
        app.staticTexts["limiter.rs"].tap()
        XCTAssertTrue(
            app.staticTexts.matching(
                NSPredicate(format: "label CONTAINS %@", "REFILL_PER_SECOND")
            ).firstMatch.waitForExistence(timeout: 15),
            "the file reader should show the demo's edited limiter"
        )
    }

    func testChangesShowsTheDiffAndItsHunks() {
        openPanel()
        section("Changes").tap()
        XCTAssertTrue(app.staticTexts["limiter.rs"].waitForExistence(timeout: 15))
        app.staticTexts["limiter.rs"].tap()
        XCTAssertTrue(
            app.staticTexts.matching(
                NSPredicate(format: "label BEGINSWITH %@", "Added line")
            ).firstMatch.waitForExistence(timeout: 15),
            "the unified diff should render added lines"
        )
    }

    func testVisualsShowsTheWorkspaceImages() {
        openPanel()
        section("Visuals").tap()
        XCTAssertTrue(
            app.buttons["assets/latency-after.png"].waitForExistence(timeout: 20)
                || app.images["assets/latency-after.png"].waitForExistence(timeout: 5),
            "the demo's two workspace images should appear"
        )
    }

    func testBackgroundWorkIsReachableAndEmptyUntilTheTurnRuns() {
        openPanel()
        section("Background Work").tap()
        XCTAssertTrue(
            app.staticTexts["Nothing in the background"].waitForExistence(timeout: 15),
            "a session whose turn has not run has nothing detached yet"
        )
    }

    func testEverySettingsPageIsNavigable() {
        hittableButton("Settings").tap()
        for page in ["General", "Appearance", "Providers", "Skills", "Usage", "Daemon", "About"] {
            let row = hittableButton(page)
            XCTAssertTrue(
                row.waitForExistence(timeout: 10), "\(page) should be a settings row")
            row.tap()
            XCTAssertTrue(
                app.navigationBars[page].waitForExistence(timeout: 20),
                "\(page) should push its own screen")
            app.navigationBars[page].buttons.firstMatch.tap()
            XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 10))
        }
    }

    func testUsageRendersItsChartAndBreakdowns() {
        hittableButton("Settings").tap()
        hittableButton("Usage").tap()
        XCTAssertTrue(app.staticTexts["Cost"].waitForExistence(timeout: 30))
        XCTAssertTrue(app.staticTexts["By day"].exists)
        XCTAssertTrue(app.staticTexts["By agent"].exists)
        XCTAssertTrue(app.otherElements["Cost per day"].exists, "the daily chart should render")
    }

    func testSkillsListsTheDemoCatalog() {
        hittableButton("Settings").tap()
        hittableButton("Skills").tap()
        XCTAssertTrue(app.staticTexts["tdd"].waitForExistence(timeout: 30))
        XCTAssertTrue(app.staticTexts["release-notes"].exists)
        app.staticTexts["tdd"].tap()
        XCTAssertTrue(app.staticTexts["Installed for"].waitForExistence(timeout: 10))
    }

    func testCommitSheetOpensFromTheTranscriptOverflow() {
        openTask()
        let more = app.buttons["More"]
        XCTAssertTrue(more.waitForExistence(timeout: 15))
        more.tap()
        let commit = app.buttons["Commit…"]
        XCTAssertTrue(commit.waitForExistence(timeout: 10))
        commit.tap()
        XCTAssertTrue(app.navigationBars["Commit"].waitForExistence(timeout: 20))
        XCTAssertTrue(app.staticTexts["demo/rate-limiter"].waitForExistence(timeout: 20))
        XCTAssertTrue(app.buttons["Write it for me"].exists)
    }

    /// One row per locale the app ships, because a translated string is only
    /// as good as the layout that survives it. Run at a large type size on
    /// purpose: the longest translation at the largest type is where a row
    /// actually breaks, and testing either alone misses it.
    private struct Localization {
        let identifier: String
        let locale: String
        let tryTheDemo: String
        let settings: String
        let general: String
    }

    private static let localizations = [
        Localization(
            identifier: "ja", locale: "ja_JP", tryTheDemo: "デモを試す", settings: "設定",
            general: "一般"),
        Localization(
            identifier: "tl", locale: "tl_PH", tryTheDemo: "Subukan ang demo",
            settings: "Settings", general: "Pangkalahatan"),
        Localization(
            identifier: "zh-CN", locale: "zh_CN", tryTheDemo: "试用演示", settings: "设置",
            general: "通用"),
    ]

    /// "The app runs in all three translated locales" from the slice's
    /// "Done when", checked rather than assumed.
    func testEveryTranslatedLocaleReachesTheSessionListAndSettings() {
        app.terminate()
        for localization in Self.localizations {
            let localized = XCUIApplication()
            localized.launchArguments = [
                "-AppleLanguages", "(\(localization.identifier))",
                "-AppleLocale", localization.locale,
                "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityM",
            ]
            localized.launch()

            let tryTheDemo = localized.buttons[localization.tryTheDemo]
            if tryTheDemo.waitForExistence(timeout: 10) { tryTheDemo.tap() }
            reachSessionList(in: localized)
            XCTAssertTrue(
                localized.staticTexts["Rate limiting in the public API"].exists,
                "\(localization.identifier): the session list should arrive"
            )

            hittableButton(localization.settings, in: localized).tap()
            let general = localized.buttons[localization.general]
            XCTAssertTrue(
                general.waitForExistence(timeout: 10),
                "\(localization.identifier): General should be a settings row"
            )
            general.tap()
            XCTAssertTrue(
                localized.navigationBars[localization.general].waitForExistence(timeout: 20),
                "\(localization.identifier): General should push its own screen"
            )
            localized.terminate()
        }
    }

    /// On iPad the surfaces are an inspector beside the transcript rather than
    /// a sheet over it, and a geometry change must not throw the user back to
    /// the session list.
    ///
    /// A true compact↔regular crossing needs Stage Manager or Split View,
    /// which XCUITest cannot drive; what is reachable from here is the
    /// regular-width presentation and the selection surviving a rotation.
    func testTheInspectorSitsBesideTheTranscriptOnIPad() throws {
        try XCTSkipUnless(
            UIDevice.current.userInterfaceIdiom == .pad,
            "the inspector is the iPad presentation"
        )
        openPanel()
        // A sheet would cover the list; the inspector sits beside it.
        XCTAssertTrue(
            app.staticTexts["Rate limiting in the public API"].exists,
            "the session list stays visible beside the inspector"
        )

        XCUIDevice.shared.orientation = .landscapeLeft
        defer { XCUIDevice.shared.orientation = .portrait }
        XCTAssertTrue(
            app.staticTexts["Files"].waitForExistence(timeout: 10),
            "the panel survives the rotation"
        )
        XCTAssertTrue(
            app.staticTexts["Rate limiting in the public API"].exists,
            "and the selected task is still the one on screen"
        )
    }

    /// Dynamic Type is where a phone layout actually breaks, and the settings
    /// rows are the densest thing this slice added.
    func testSettingsSurviveAnAccessibilityTypeSize() {
        app.terminate()
        app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityL"]
        app.launch()
        reachSessionList(in: app)
        hittableButton("Settings").tap()
        for page in ["General", "Appearance", "Providers"] {
            XCTAssertTrue(app.buttons[page].waitForExistence(timeout: 10))
            app.buttons[page].tap()
            XCTAssertTrue(app.navigationBars[page].waitForExistence(timeout: 20))
            app.navigationBars[page].buttons.firstMatch.tap()
        }
    }
}
