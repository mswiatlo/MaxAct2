import AppKit
import XCTest

/// Clearing stored data from Settings.
final class DeleteDataUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    private func launchSeeded(_ count: Int) -> XCUIApplication {
        launchMaxAct(seed: count)
    }

    /// A button inside the frontmost dialog, **not** its Touch Bar mirror.
    ///
    /// macOS duplicates alert buttons onto the Touch Bar, and `app.buttons[...].firstMatch` picks
    /// the mirror, which then fails with "cannot be called with Touch Bar elements". Scoping to
    /// sheets and dialogs avoids it.
    @MainActor
    private func dialogButton(_ label: String, in app: XCUIApplication) -> XCUIElement {
        for container in [app.sheets, app.dialogs, app.windows] {
            let button = container.buttons[label]
            if button.firstMatch.exists { return button.firstMatch }
        }
        return app.sheets.buttons[label].firstMatch
    }

    /// Destructive actions must confirm, and the confirmation should say what it costs to undo.
    @MainActor
    func testDeletingAsksFirstAndCanBeCancelled() throws {
        let app = launchSeeded(12)
        app.typeKey(",", modifierFlags: .command)

        let deleteButton = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH 'Delete All Workouts'")
        ).firstMatch
        XCTAssertTrue(deleteButton.waitForExistence(timeout: 10), "Settings should offer to clear data.")
        deleteButton.click()

        XCTAssertTrue(
            app.staticTexts.containing(
                NSPredicate(format: "value CONTAINS[c] 'Delete all 12 workouts'")
            ).firstMatch.waitForExistence(timeout: 10),
            "Deleting should confirm, naming how much will go."
        )

        dialogButton("Cancel", in: app).click()

        // Cancelling must actually cancel.
        app.typeKey("w", modifierFlags: .command)
        XCTAssertTrue(
            app.staticTexts.containing(
                NSPredicate(format: "value CONTAINS %@", "12 workouts")
            ).firstMatch.waitForExistence(timeout: 10),
            "Cancelling the dialog should leave the library intact."
        )
    }

    @MainActor
    func testConfirmingDeleteEmptiesTheLibrary() throws {
        let app = launchSeeded(12)
        app.typeKey(",", modifierFlags: .command)

        app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH 'Delete All Workouts'")
        ).firstMatch.click()

        // The confirmation's own button carries no ellipsis, unlike the one that opened it.
        dialogButton("Delete All Workouts", in: app).click()
        app.typeKey("w", modifierFlags: .command)

        XCTAssertTrue(
            app.buttons.matching(
                NSPredicate(format: "label CONTAINS[c] 'Sync Now' OR label CONTAINS[c] 'Set Up Sync'")
            ).firstMatch.waitForExistence(timeout: 15),
            "After deleting everything the library should be back to its empty state."
        )
    }
}
