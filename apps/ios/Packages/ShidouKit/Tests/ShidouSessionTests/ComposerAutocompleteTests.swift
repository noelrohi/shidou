import ShidouProtocol
import XCTest

@testable import ShidouSession

/// Ported case-for-case from `apps/web/src/lib/composer-autocomplete.test.ts`.
/// Both clients complete against the same daemon answers, so a divergence here
/// is a divergence a user would see between their phone and their browser.
final class ComposerAutocompleteTests: XCTestCase {
    private func command(
        _ name: String,
        _ scope: CommandScope,
        _ description: String,
        _ template: String?
    ) -> SlashCommand {
        SlashCommand(name: name, description: description, scope: scope, template: template)
    }

    func testDetectsSlashCommandsOnlyAtTheStartOfTheCurrentLine() {
        XCTAssertEqual(
            ComposerAutocomplete.trigger(in: "intro\n/rev", cursor: 10),
            ComposerTrigger(kind: .command, query: "rev", start: 6, end: 10)
        )
        XCTAssertNil(ComposerAutocomplete.trigger(in: "intro /rev", cursor: 10))
        XCTAssertNil(ComposerAutocomplete.trigger(in: "/review now", cursor: 11))
    }

    func testDetectsTheCurrentWhitespaceDelimitedFileMention() {
        XCTAssertEqual(
            ComposerAutocomplete.trigger(in: "look at @src/app", cursor: 16),
            ComposerTrigger(kind: .file, query: "src/app", start: 8, end: 16)
        )
        XCTAssertNil(ComposerAutocomplete.trigger(in: "email@example.com", cursor: 17))
    }

    func testReplacesOnlyTheActiveTokenAndLeavesTheCaretAfterATrailingSpace() throws {
        let text = "read @app then"
        let trigger = try XCTUnwrap(ComposerAutocomplete.trigger(in: text, cursor: 9))
        let replacement = ComposerAutocomplete.replacing(
            text, trigger: trigger, with: .file(FileEntry(path: "src/app.ts", isDir: false)))
        XCTAssertEqual(replacement.text, "read @src/app.ts  then")
        XCTAssertEqual(replacement.cursor, 17)
    }

    func testMergesLiveProviderCommandsWithoutLosingDiscoveredTemplates() {
        let discovered = [
            command("review", .project, "Review changes", "Review $ARGUMENTS"),
            command("deploy", .skill, "Deploy the app", nil),
        ]
        let reported = [
            ReportedCommand(name: "review", description: "Provider review"),
            ReportedCommand(name: "compact", description: "Compact context"),
        ]
        XCTAssertEqual(
            ComposerAutocomplete.mergeCommands(discovered: discovered, reported: reported),
            [
                command("compact", .builtin, "Compact context", nil),
                discovered[0],
                discovered[1],
            ]
        )
    }

    func testRecognizesOnlyTheResolvedCodexFastModeCommand() {
        let builtin = command("fast", .builtin, "Toggle fast mode", nil)
        XCTAssertTrue(
            ComposerAutocomplete.isFastModeToggle(
                provider: .codex, prompt: "/fast ", commands: [builtin]))
        XCTAssertFalse(
            ComposerAutocomplete.isFastModeToggle(
                provider: .claude, prompt: "/fast", commands: [builtin]))
        XCTAssertFalse(
            ComposerAutocomplete.isFastModeToggle(
                provider: .codex, prompt: "/fast now", commands: [builtin]))
        XCTAssertFalse(
            ComposerAutocomplete.isFastModeToggle(
                provider: .codex,
                prompt: "/fast",
                commands: [command("fast", .project, "Project fast command", "Run fast")]
            ))
    }

    func testTogglesTheConcreteFastServiceTierTheModelReports() {
        let tiers = [ProviderModelOption(id: "priority", label: "Fast", description: nil)]
        XCTAssertEqual(
            ComposerAutocomplete.toggledFastServiceTier(current: "default", serviceTiers: tiers),
            "priority")
        XCTAssertEqual(
            ComposerAutocomplete.toggledFastServiceTier(current: "priority", serviceTiers: tiers),
            "default")
        XCTAssertNil(
            ComposerAutocomplete.toggledFastServiceTier(current: nil, serviceTiers: []))
    }

    func testFiltersByFuzzyPathAndCapsTheResultCount() {
        let files = (0..<100).map { FileEntry(path: "src/component-\($0).tsx", isDir: false) }
        let trigger = ComposerTrigger(kind: .file, query: "cmp1", start: 0, end: 5)
        let rows = ComposerAutocomplete.rows(
            for: trigger, commands: [], files: files, cap: 3)
        XCTAssertEqual(rows.count, 3)
        XCTAssertTrue(rows.allSatisfy { if case .file = $0 { return true } else { return false } })
    }

    // MARK: - Slash-command templates

    func testExpandsAllArgumentAndPositionalPlaceholders() {
        XCTAssertEqual(
            ComposerAutocomplete.expandTemplate(
                "All: $ARGUMENTS / $@ / $1 / $3", arguments: "one two three"),
            "All: one two three / one two three / one / three"
        )
    }

    func testAppendsArgumentsWhenATemplateHasNoPlaceholder() {
        XCTAssertEqual(
            ComposerAutocomplete.expandTemplate("Review this project", arguments: "carefully"),
            "Review this project\n\ncarefully"
        )
    }

    func testExpandsOnlyAKnownCommandWithATemplate() {
        let commands = [command("review", .project, "", "Review $ARGUMENTS")]
        XCTAssertEqual(
            ComposerAutocomplete.expandedSubmission(
                provider: .openCode, prompt: "/review src", commands: commands),
            "Review src")
        XCTAssertNil(
            ComposerAutocomplete.expandedSubmission(
                provider: .openCode, prompt: "/unknown src", commands: commands))
        XCTAssertNil(
            ComposerAutocomplete.expandedSubmission(
                provider: .openCode, prompt: "please /review src", commands: commands))
    }

    func testUsesEachProvidersNativeSkillInvocation() {
        let commands = [command("deploy", .skill, "", nil)]
        XCTAssertEqual(
            ComposerAutocomplete.expandedSubmission(
                provider: .fx, prompt: "/deploy production", commands: commands),
            "$deploy production")
        XCTAssertEqual(
            ComposerAutocomplete.expandedSubmission(
                provider: .pi, prompt: "/deploy production", commands: commands),
            "/skill:deploy production")
    }
}
