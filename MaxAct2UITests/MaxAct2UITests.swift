import XCTest

/// Launch and structure checks.
///
/// The app is launched by bundle identifier rather than via `XCUIApplication()`, because
/// `TEST_TARGET_NAME` — the setting that supplies the implicit target application — is not
/// writable through the available tooling. The scheme's build action builds the app for testing,
/// so the bundle is present by the time this runs.
///
/// These run against whatever is in the real database, so they assert on structure that holds
/// either way rather than on specific rows. Phase 8 adds a seeded multi-select and batch-action
/// test once there's a way to launch with fixture data.
final class MaxAct2UITests: XCTestCase {
    private static let appBundleIdentifier = "com.swiatlowski.MaxAct"

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// Launches the app and registers its termination.
    ///
    /// `XCUIApplication` and `terminate()` are main-actor-isolated while `setUp` and `tearDown`
    /// are not, so holding the app in a stored property and terminating it in `tearDown` warns
    /// under Swift 6. Creating it inside each `@MainActor` test and tearing down through
    /// `MainActor.run` keeps every touch of it on the main actor.
    @MainActor
    private func launchApp() -> XCUIApplication {
        let app = XCUIApplication(bundleIdentifier: Self.appBundleIdentifier)
        // Isolates the app's defaults and database from the real ones. These tests type into the
        // connection fields, and without this a test run overwrites the user's own token.
        app.launchArguments = ["--ui-testing"]
        app.launch()
        addTeardownBlock { await MainActor.run { app.terminate() } }
        XCTAssertTrue(
            app.windows.firstMatch.waitForExistence(timeout: 10),
            "The app launched but no window appeared."
        )
        return app
    }

    @MainActor
    func testAppLaunchesAndShowsMainWindow() throws {
        let app = launchApp()
        XCTAssertTrue(app.windows.firstMatch.exists)
    }

    @MainActor
    func testSidebarOffersTheSavedFilters() throws {
        let app = launchApp()

        // Each row exposes label "<title>, <n> workouts" with the count as its value — the right
        // shape for VoiceOver, and a predicate is needed because the count is part of the label.
        let sidebar = app.outlines["Sidebar"]
        XCTAssertTrue(sidebar.waitForExistence(timeout: 5))

        for title in ["All Workouts", "Not on Strava", "Upload Failed", "With Route", "Indoor"] {
            let row = sidebar.staticTexts.containing(
                NSPredicate(format: "label BEGINSWITH %@", title)
            ).firstMatch
            XCTAssertTrue(row.waitForExistence(timeout: 5), "Sidebar is missing '\(title)'.")
            XCTAssertTrue(
                row.label.contains("workouts"),
                "Sidebar row should announce its count for VoiceOver."
            )
        }
    }

    @MainActor
    func testSyncAndSelectionCommandsExistInTheMenus() throws {
        let app = launchApp()

        // Mac convention: every action must be reachable from the menu bar, not just the toolbar.
        let fileMenu = app.menuBars.menuBarItems["File"]
        XCTAssertTrue(fileMenu.waitForExistence(timeout: 5))
        fileMenu.click()
        // Trailing ellipsis: the command opens the sync panel rather than acting immediately.
        XCTAssertTrue(
            app.menuItems["Sync from iPhone…"].waitForExistence(timeout: 3),
            "Sync should be in the File menu with a keyboard shortcut."
        )
        XCTAssertTrue(app.menuItems["Download Detail for Selection"].exists)
        app.typeKey(.escape, modifierFlags: [])

        let editMenu = app.menuBars.menuBarItems["Edit"]
        editMenu.click()
        XCTAssertTrue(app.menuItems["Select All Visible"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.menuItems["Deselect All"].exists)
        app.typeKey(.escape, modifierFlags: [])
    }

    @MainActor
    func testSettingsExplainsTheForegroundRequirement() throws {
        let app = launchApp()
        app.typeKey(",", modifierFlags: .command)

        // The foreground/unlocked constraint is the single most confusing thing about this app,
        // so the settings window must state it rather than leaving people to guess.
        let explanation = app.staticTexts.containing(
            NSPredicate(format: "value CONTAINS[c] 'foreground'")
        ).firstMatch
        XCTAssertTrue(
            explanation.waitForExistence(timeout: 5),
            "Settings should explain that Health Auto Export must stay in the foreground."
        )
    }

    /// Regression test for a real dead end: the first version of the empty state read "Add your
    /// iPhone's address in Settings, then sync" and offered **no button at all** — no way to reach
    /// Settings, and a permanently-disabled unlabelled toolbar icon as the only other affordance.
    /// There was literally nothing to click.
    @MainActor
    func testThereIsAlwaysAWayToStartSyncing() throws {
        let app = launchApp()

        // The toolbar button must be labelled and enabled, not a disabled mystery icon.
        let syncButton = app.buttons["Sync"]
        XCTAssertTrue(syncButton.waitForExistence(timeout: 5), "Toolbar has no labelled Sync button.")
        XCTAssertTrue(syncButton.isEnabled, "Sync must be reachable even before configuration.")

        // And the empty state must offer an action rather than describing one.
        let emptyStateAction = app.buttons.matching(
            NSPredicate(format: "label CONTAINS[c] 'Sync'")
        ).count
        XCTAssertGreaterThan(emptyStateAction, 1, "Empty state offers no button to start syncing.")
    }

    @MainActor
    func testSyncPanelExplainsSetupAndOffersSettings() throws {
        let app = launchApp()
        app.buttons["Sync"].click()

        // The panel must explain where the address and token come from. Matching on "Health Auto
        // Export" rather than an exact sentence: the copy contains markdown emphasis, which
        // fragments the accessibility value and makes a phrase match brittle.
        XCTAssertTrue(
            app.staticTexts.containing(
                NSPredicate(format: "value CONTAINS[c] 'Health Auto Export'")
            ).firstMatch.waitForExistence(timeout: 5),
            "Sync panel should explain where the address and token come from."
        )
        XCTAssertTrue(
            app.buttons.matching(
                NSPredicate(format: "label CONTAINS[c] 'Settings'")
            ).firstMatch.exists,
            "Sync panel should still offer a route to Settings."
        )
    }

    /// Regression test for the reported bug: pressing Sync or ⌘R opened Settings and never
    /// synced, because the address had silently stayed empty and the panel's only affordance in
    /// that state was a link to Settings. The connection fields now live in the panel itself.
    @MainActor
    func testSyncPanelHoldsTheConnectionFields() throws {
        let app = launchApp()
        app.buttons["Sync"].click()

        let addressField = app.textFields.element(boundBy: 0)
        XCTAssertTrue(
            addressField.waitForExistence(timeout: 5),
            "The sync panel must let you enter the iPhone address without leaving for Settings."
        )
        XCTAssertGreaterThanOrEqual(
            app.textFields.count, 2,
            "Both the address and the token belong in the panel."
        )
        XCTAssertTrue(
            app.buttons["Start Sync"].exists,
            "The panel must offer a way to actually start syncing."
        )
    }

    @MainActor
    func testCommandROpensTheSyncPanel() throws {
        let app = launchApp()
        app.typeKey("r", modifierFlags: .command)

        XCTAssertTrue(
            app.buttons["Start Sync"].waitForExistence(timeout: 5),
            "⌘R should open the sync panel, not do nothing and not open Settings."
        )
    }

    /// Typing an address should be enough to make syncing possible — the previous flow left you
    /// with a permanently disabled action and no indication of what was missing.
    @MainActor
    func testEnteringAnAddressEnablesSyncing() throws {
        let app = launchApp()
        app.buttons["Sync"].click()

        let startSync = app.buttons["Start Sync"]
        XCTAssertTrue(startSync.waitForExistence(timeout: 5))

        let address = app.textFields.element(boundBy: 0)
        address.click()
        address.typeKey("a", modifierFlags: .command)
        address.typeText("10.0.0.158")

        let token = app.textFields.element(boundBy: 1)
        token.click()
        token.typeKey("a", modifierFlags: .command)
        token.typeText("test-token")

        XCTAssertTrue(
            startSync.isEnabled,
            "With an address and a token entered, Start Sync must be available."
        )
    }
}
