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
    private func launchApp(seed: Int? = nil) -> XCUIApplication {
        let app = XCUIApplication(bundleIdentifier: Self.appBundleIdentifier)
        // Isolates the app's defaults and database from the real ones. These tests type into the
        // connection fields, and without this a test run overwrites the user's own token.
        app.launchArguments = ["--ui-testing"]
        if let seed { app.launchArguments += ["--ui-testing-seed", String(seed)] }
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

    /// Smoke test for the Start Sync path: enter a connection, start a sync, and keep poking the
    /// window while it runs.
    ///
    /// **This does not reproduce the "No Observable object of type AppModel found" crash** that
    /// prompted the fix in `SyncPanel`. That was seen once against a real, reachable phone; this
    /// test was checked against the pre-fix code and still passed, so treat it as coverage of the
    /// path rather than proof the crash is gone.
    @MainActor
    func testStartingASyncDoesNotCrash() throws {
        let app = launchApp()
        app.buttons["Sync"].click()

        let address = app.textFields.element(boundBy: 0)
        XCTAssertTrue(address.waitForExistence(timeout: 5))
        address.click()
        address.typeText("10.255.255.1")     // unroutable: the sync stays "running"

        let token = app.textFields.element(boundBy: 1)
        token.click()
        token.typeText("irrelevant")

        let startSync = app.buttons["Start Sync"]
        XCTAssertTrue(startSync.isEnabled)
        startSync.click()

        // The crash happened here, as the banner appeared and the popover was torn down.
        XCTAssertTrue(
            app.windows.firstMatch.waitForExistence(timeout: 10),
            "The app crashed while starting a sync."
        )
        XCTAssertTrue(app.buttons["Sync"].waitForExistence(timeout: 10), "The app is gone.")

        // Keep the window busy while the sync is in its running state: the crash happened during
        // a main-window re-layout with the popover hierarchy still alive.
        for _ in 0..<5 {
            app.buttons["Sync"].click()
            Thread.sleep(forTimeInterval: 0.4)
            app.typeKey(.escape, modifierFlags: [])
            Thread.sleep(forTimeInterval: 0.4)
            XCTAssertTrue(app.windows.firstMatch.exists, "The app crashed during re-layout.")
        }

        // And the failure should be reported rather than swallowed.
        let banner = app.staticTexts.containing(
            NSPredicate(format: "value CONTAINS[c] 'Health Auto Export' OR value CONTAINS[c] 'reach'")
        ).firstMatch
        XCTAssertTrue(
            banner.waitForExistence(timeout: 20),
            "A failed sync should explain itself in the banner."
        )
    }
}

/// Tests that need rows on screen.
///
/// Every user-visible bug found so far escaped the suite for the same reason: the tests ran
/// against an empty database, so the table, the thumbnail pipeline and the detail pane had
/// nothing to go wrong with. These launch with `--ui-testing-seed`, which plants deterministic
/// synthetic workouts — some with a stored route, some awaiting download, some indoor — in the
/// throwaway in-memory store.
final class SeededTableUITests: XCTestCase {
    private static let appBundleIdentifier = "com.swiatlowski.MaxAct"

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    private func launchSeeded(_ count: Int = 40) -> XCUIApplication {
        let app = XCUIApplication(bundleIdentifier: Self.appBundleIdentifier)
        app.launchArguments = ["--ui-testing", "--ui-testing-seed", String(count)]
        app.launch()
        addTeardownBlock { await MainActor.run { app.terminate() } }
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 15))
        return app
    }

    @MainActor
    func testSeededWorkoutsAppearInTheTable() throws {
        let app = launchSeeded()
        // The subtitle reports the visible count, which proves the seed reached the table rather
        // than merely the store.
        XCTAssertTrue(
            app.staticTexts.containing(
                NSPredicate(format: "value CONTAINS %@", "40 workouts")
            ).firstMatch.waitForExistence(timeout: 15),
            "Seeded workouts did not reach the table."
        )
    }

    /// Regression test for the crash that reached the user: scrolling trapped with "No Observable
    /// object of type AppModel found", because a table cell is hosted in a detached
    /// `NSHostingView` that doesn't inherit the environment. No previous test could reach this —
    /// there were never any cells.
    @MainActor
    func testScrollingASeededTableDoesNotCrash() throws {
        let app = launchSeeded(60)
        let table = app.outlines["WorkoutTable"]
        XCTAssertTrue(table.waitForExistence(timeout: 15))

        for _ in 0..<6 {
            table.scroll(byDeltaX: 0, deltaY: -260)
            XCTAssertTrue(app.windows.firstMatch.exists, "The app crashed while scrolling.")
        }
        for _ in 0..<6 {
            table.scroll(byDeltaX: 0, deltaY: 260)
            XCTAssertTrue(app.windows.firstMatch.exists, "The app crashed while scrolling back.")
        }
        XCTAssertTrue(app.buttons["Sync"].isEnabled, "The app is no longer responsive.")
    }

    /// Regression test for the indoor icon appearing on every outdoor ride. The placeholder used
    /// to key "indoor" off `hasRoute == false`, which after a list pass means *unknown*.
    ///
    /// Asserted through accessibility labels rather than pixels, so it holds without a network.
    @MainActor
    func testThumbnailPlaceholdersDistinguishTheirThreeStates() throws {
        let app = launchSeeded()
        XCTAssertTrue(app.outlines["WorkoutTable"].waitForExistence(timeout: 15))

        // Outdoor, no series yet: awaiting download — emphatically not "indoor".
        XCTAssertTrue(
            app.images["Route not downloaded yet"].firstMatch.waitForExistence(timeout: 15),
            "An outdoor workout without a stored route should offer to download it."
        )
        // Indoor workouts are seeded too, and those *should* say indoor.
        XCTAssertTrue(
            app.images["Indoor workout"].firstMatch.exists,
            "Indoor workouts should be marked as such."
        )
    }

    /// Exercises the whole thumbnail chain: stored series → simplify → snapshot → bitmap.
    ///
    /// Network-independent despite using `MKMapSnapshotter`, because the renderer falls back to
    /// drawing the polyline alone when tiles can't be fetched — either way an image appears. A
    /// hang produces no image at all, which is what the released-snapshotter bug did.
    @MainActor
    func testSeededRoutesRenderThumbnails() throws {
        let app = launchSeeded()
        XCTAssertTrue(app.outlines["WorkoutTable"].waitForExistence(timeout: 15))

        XCTAssertTrue(
            app.images["Route map"].firstMatch.waitForExistence(timeout: 45),
            "No thumbnail rendered for a workout with a stored route."
        )
    }

    @MainActor
    func testSelectingARowShowsItsDetail() throws {
        let app = launchSeeded()
        let table = app.outlines["WorkoutTable"]
        XCTAssertTrue(table.waitForExistence(timeout: 15))

        table.cells.element(boundBy: 0).click()
        XCTAssertTrue(
            app.staticTexts.containing(
                NSPredicate(format: "value CONTAINS[c] 'Duration'")
            ).firstMatch.waitForExistence(timeout: 10),
            "Selecting a row should show its stats."
        )
    }

    /// Multi-select and the aggregate summary — the reason the table exists — had no coverage.
    @MainActor
    func testSelectAllShowsAnAggregateSummary() throws {
        let app = launchSeeded()
        let table = app.outlines["WorkoutTable"]
        XCTAssertTrue(table.waitForExistence(timeout: 15))

        table.cells.element(boundBy: 0).click()
        app.typeKey("a", modifierFlags: [.command, .shift])

        XCTAssertTrue(
            app.staticTexts.containing(
                NSPredicate(format: "value CONTAINS[c] 'Workouts Selected'")
            ).firstMatch.waitForExistence(timeout: 10),
            "Selecting many rows should show the aggregate summary."
        )
        XCTAssertTrue(
            app.staticTexts.containing(
                NSPredicate(format: "value CONTAINS[c] 'Total Distance'")
            ).firstMatch.exists,
            "The summary should total the selection."
        )
    }

    @MainActor
    func testSidebarFiltersNarrowTheTable() throws {
        let app = launchSeeded()
        let sidebar = app.outlines["Sidebar"]
        XCTAssertTrue(sidebar.waitForExistence(timeout: 15))

        // "Indoor" is seeded to be a strict subset, so the count must drop.
        let indoor = sidebar.staticTexts.containing(
            NSPredicate(format: "label BEGINSWITH 'Indoor'")
        ).firstMatch
        XCTAssertTrue(indoor.waitForExistence(timeout: 10))
        indoor.click()

        XCTAssertFalse(
            app.staticTexts.containing(
                NSPredicate(format: "value CONTAINS %@", "40 workouts")
            ).firstMatch.exists,
            "Choosing Indoor should show fewer than all 40 workouts."
        )
    }
}

/// The bulk detail backfill, which only means anything with rows present.
final class DetailBackfillUITests: XCTestCase {
    private static let appBundleIdentifier = "com.swiatlowski.MaxAct"

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    private func launchSeeded(_ count: Int) -> XCUIApplication {
        let app = XCUIApplication(bundleIdentifier: Self.appBundleIdentifier)
        app.launchArguments = ["--ui-testing", "--ui-testing-seed", String(count)]
        app.launch()
        addTeardownBlock { await MainActor.run { app.terminate() } }
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 15))
        return app
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

/// Clearing stored data from Settings.
final class DeleteDataUITests: XCTestCase {
    private static let appBundleIdentifier = "com.swiatlowski.MaxAct"

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    private func launchSeeded(_ count: Int) -> XCUIApplication {
        let app = XCUIApplication(bundleIdentifier: Self.appBundleIdentifier)
        app.launchArguments = ["--ui-testing", "--ui-testing-seed", String(count)]
        app.launch()
        addTeardownBlock { await MainActor.run { app.terminate() } }
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 15))
        return app
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
