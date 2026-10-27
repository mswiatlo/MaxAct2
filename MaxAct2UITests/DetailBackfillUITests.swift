import AppKit
import XCTest

/// The bulk detail backfill, which only means anything with rows present.
final class DetailBackfillUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    private func launchSeeded(_ count: Int) -> XCUIApplication {
        launchMaxAct(seed: count)
    }

    /// The cost has to be visible before committing, not discovered in a progress bar: a full
    /// backlog is hours of foregrounded phone.
    @MainActor
    func testBackfillButtonStatesTheCountAndTheCost() throws {
        let app = launchSeeded(30)
        app.buttons["Sync"].click()

        // Seeded data gives a series to every third outdoor workout, so most rows lack detail.
        let button = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH 'Download ' AND label CONTAINS 'Workout'")
        ).firstMatch
        XCTAssertTrue(
            button.waitForExistence(timeout: 10),
            "The sync panel should offer to download the missing detail."
        )
        XCTAssertTrue(
            button.label.contains("second") || button.label.contains("minute")
                || button.label.contains("hour"),
            "The button should state the time it will take, not just the count. Got: \(button.label)"
        )
    }

    /// With nothing configured there is no server to talk to, so the action must not be offered
    /// as though it would work.
    @MainActor
    func testBackfillIsDisabledWithoutAServer() throws {
        let app = launchSeeded(10)
        app.buttons["Sync"].click()

        let button = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH 'Download ' AND label CONTAINS 'Workout'")
        ).firstMatch
        XCTAssertTrue(button.waitForExistence(timeout: 10))
        XCTAssertFalse(button.isEnabled, "Backfill needs a configured server.")
    }

    /// A scope choice only earns its space when the filter actually narrows the backlog.
    @MainActor
    func testScopeChoiceAppearsOnlyWhenTheFilterNarrowsThings() throws {
        let app = launchSeeded(30)

        // Unfiltered: every workout is in scope, so there is nothing to choose between.
        app.buttons["Sync"].click()
        XCTAssertFalse(
            app.radioButtons.matching(
                NSPredicate(format: "label CONTAINS[c] 'Current filter'")
            ).firstMatch.exists,
            "No scope choice is needed when the filter shows everything."
        )
        app.typeKey(.escape, modifierFlags: [])

        // Narrow to one activity, then the choice becomes meaningful.
        let sidebar = app.outlines["Sidebar"]
        XCTAssertTrue(sidebar.waitForExistence(timeout: 10))
        sidebar.staticTexts.containing(
            NSPredicate(format: "label BEGINSWITH 'Running'")
        ).firstMatch.click()

        app.buttons["Sync"].click()
        XCTAssertTrue(
            app.radioButtons.matching(
                NSPredicate(format: "label CONTAINS[c] 'Current filter'")
            ).firstMatch.waitForExistence(timeout: 10),
            "With a filter narrowing the backlog, the scope choice should appear."
        )
    }
}
