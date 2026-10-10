import XCTest

extension XCTestCase {
    /// Launches MaxAct for a UI test, **brings it to the front**, and waits for its window.
    ///
    /// The one launch path for every suite, which used to be four copies.
    ///
    /// **`-ApplePersistenceIgnoreState YES` is what makes the window appear at all.** macOS
    /// restores the previous session's windows, and a session that ended with none open — a
    /// test that closed its window, or the user quitting from the menu with it closed — relaunches
    /// with *no window*. Activating the app doesn't create one; only a Dock click (a "reopen") does,
    /// which is why the suite passed whenever someone clicked the app into focus and failed, in a
    /// different subset each run, whenever they didn't. Diagnosed with the window server: a
    /// background launch had zero windows where Calculator had one, and the unified log showed
    /// `hasPersistentStateToRestore=1`.
    ///
    /// **It must come first.** `NSUserDefaults` pairs each `-key` with the following token, so
    /// after `--ui-testing` it would be swallowed as that flag's value and silently do nothing —
    /// the same trap documented on `MaxActApp.uiTestingSeedCount`.
    ///
    /// `activate()` then brings it forward, since activation is cooperative and a launched app
    /// won't take focus from whatever the user is working in.
    ///
    /// Also isolates the app's data: `--ui-testing` swaps in a throwaway defaults domain,
    /// in-memory database and separate Keychain service. These tests type into the connection
    /// fields, and without it a test run once overwrote the user's real token.
    @MainActor
    func launchMaxAct(seed: Int? = nil) -> XCUIApplication {
        let app = XCUIApplication(bundleIdentifier: "com.swiatlowski.MaxAct")
        app.launchArguments = ["-ApplePersistenceIgnoreState", "YES", "--ui-testing"]
        // `=` joined, never two tokens — see `MaxActApp.uiTestingSeedCount` for why.
        if let seed { app.launchArguments.append("--ui-testing-seed=\(seed)") }
        app.launch()
        addTeardownBlock { await MainActor.run { app.terminate() } }

        app.activate()
        XCTAssertTrue(
            app.wait(for: .runningForeground, timeout: 10),
            "The app launched but couldn't be brought to the front."
        )
        XCTAssertTrue(
            app.windows.firstMatch.waitForExistence(timeout: 15),
            "The app launched but no window appeared."
        )
        return app
    }
}

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
        launchMaxAct(seed: seed)
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
        // Select All is the system's, not ours — asserted here so a stray custom item that would
        // make ⌘A ambiguous gets noticed.
        XCTAssertTrue(app.menuItems["Select All"].waitForExistence(timeout: 3))
        XCTAssertEqual(
            app.menuItems.matching(NSPredicate(format: "title BEGINSWITH 'Select All'")).count, 1,
            "Two Select All items would mean two ⌘A entries in one menu."
        )
        XCTAssertTrue(app.menuItems["Deselect All"].exists)
        app.typeKey(.escape, modifierFlags: [])
    }

    /// One library, one window: no tabs, no New Window, and ⌘N doesn't make a second window.
    ///
    /// Multiple windows came free with `WindowGroup` and only looked independent — they all
    /// shared the model's filter, search and selection. The keystroke is checked as well as the
    /// menus, because removing a menu item and removing its behaviour are different things.
    @MainActor
    func testThereIsOnlyEverOneWindow() throws {
        let app = launchApp()

        let fileMenu = app.menuBars.menuBarItems["File"]
        fileMenu.click()
        XCTAssertTrue(app.menuItems["Sync from iPhone…"].waitForExistence(timeout: 3),
                      "Removing New Window must not take the File menu's own items with it.")
        XCTAssertFalse(app.menuItems["New Window"].exists, "File ▸ New Window is still offered.")
        app.typeKey(.escape, modifierFlags: [])

        let viewMenu = app.menuBars.menuBarItems["View"]
        viewMenu.click()
        XCTAssertTrue(app.menuItems["Hide Sidebar"].waitForExistence(timeout: 3))
        for tabItem in ["Show Tab Bar", "Hide Tab Bar", "Show All Tabs"] {
            XCTAssertFalse(app.menuItems[tabItem].exists, "View ▸ \(tabItem) is still offered.")
        }
        app.typeKey(.escape, modifierFlags: [])

        app.typeKey("n", modifierFlags: .command)
        Thread.sleep(forTimeInterval: 1)
        XCTAssertEqual(app.windows.count, 1, "⌘N opened a second window.")
    }

    /// View ▸ Hide Sidebar exists, ⌃⌘S really toggles it, and the title tells the truth.
    ///
    /// The title is the point. The first version used `SidebarCommands()`, whose shortcut worked
    /// but whose item read "Show Sidebar" in *both* states — the split view's visibility is SwiftUI
    /// state, and that command validated against AppKit's. Asserts on width, not `exists`, since a
    /// collapsed sidebar can linger in the accessibility tree.
    @MainActor
    func testTheSidebarCanBeToggledFromTheViewMenu() throws {
        let app = launchApp()
        let sidebar = app.outlines["Sidebar"]
        XCTAssertTrue(sidebar.waitForExistence(timeout: 5))
        XCTAssertGreaterThan(sidebar.frame.width, 100)

        let viewMenu = app.menuBars.menuBarItems["View"]
        func menuTitles() -> [String] {
            viewMenu.click()
            _ = viewMenu.menuItems.firstMatch.waitForExistence(timeout: 3)
            let titles = viewMenu.menuItems.allElementsBoundByIndex.map(\.title)
            app.typeKey(.escape, modifierFlags: [])
            return titles
        }
        func wait(_ condition: @escaping () -> Bool, _ message: String) {
            let expectation = XCTNSPredicateExpectation(
                predicate: NSPredicate { _, _ in condition() }, object: nil)
            XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 5), .completed, message)
        }

        var titles = menuTitles()
        XCTAssertTrue(titles.contains("Hide Sidebar"), "View menu was \(titles)")
        XCTAssertEqual(titles.filter { $0.hasSuffix("Sidebar") }.count, 1,
                       "Two sidebar items would mean two ⌃⌘S entries.")

        app.typeKey("s", modifierFlags: [.command, .control])
        wait({ !sidebar.exists || sidebar.frame.width < 10 }, "⌃⌘S didn't hide the sidebar.")
        titles = menuTitles()
        XCTAssertTrue(titles.contains("Show Sidebar"),
                      "With the sidebar hidden the item should offer to show it; was \(titles)")

        app.typeKey("s", modifierFlags: [.command, .control])
        wait({ sidebar.exists && sidebar.frame.width > 100 }, "⌃⌘S didn't bring the sidebar back.")
        XCTAssertTrue(menuTitles().contains("Hide Sidebar"))
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
/// nothing to go wrong with. These launch with `--ui-testing-seed=<n>`, which plants deterministic
/// synthetic workouts — some with a stored route, some awaiting download, some indoor — in the
/// throwaway in-memory store.
final class SeededTableUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    private func launchSeeded(_ count: Int = 40) -> XCUIApplication {
        launchMaxAct(seed: count)
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

    /// The detail pane's series must belong to the workout selected *now*.
    ///
    /// Context: SwiftUI reuses `WorkoutDetailView` across selection changes — same view type, same
    /// place in the hierarchy — so its `@State` survives. That is what made the map camera, set
    /// once through `initialPosition`, keep the first workout's region forever, and what left the
    /// previous route drawn under the new header while the next series loaded.
    ///
    /// Be clear about the limit of this test: it asserts the settled state, which the old code
    /// also reached once its load finished. The camera region isn't exposed to accessibility and
    /// the transient is too brief to sample, so neither is asserted here — the camera was checked
    /// by hand against real workouts in different cities. What this does catch is the series and
    /// the header disagreeing, which is the failure mode the id tagging rules out structurally.
    @MainActor
    func testDetailFollowsTheSelectionRatherThanLagging() throws {
        let app = launchSeeded()
        let sidebar = app.outlines["Sidebar"]
        XCTAssertTrue(sidebar.waitForExistence(timeout: 15))

        // Narrow to workouts that have a stored route, so both rows clicked below definitely have
        // a series to draw and the test doesn't depend on which seed indices got one.
        let withRoute = sidebar.staticTexts.containing(
            NSPredicate(format: "label BEGINSWITH 'With Route'")
        ).firstMatch
        XCTAssertTrue(withRoute.waitForExistence(timeout: 10))
        withRoute.click()

        let table = app.outlines["WorkoutTable"]
        XCTAssertTrue(table.waitForExistence(timeout: 15))

        let samples = app.staticTexts.containing(
            NSPredicate(format: "value CONTAINS[c] 'pts ·'")
        ).firstMatch

        table.cells.element(boundBy: 0).click()
        XCTAssertTrue(samples.waitForExistence(timeout: 10), "The first selection showed no series.")
        let first = samples.value as? String

        // Down arrow rather than clicking another cell: `cells` on an outline enumerates every
        // column, so cell 1 is still the *first* row and the selection would never change.
        app.typeKey(.downArrow, modifierFlags: [])
        var second = samples.value as? String
        // Allow for the load: the assertion is that it *arrives* at the new workout's figures,
        // not that it changes synchronously.
        let deadline = Date().addingTimeInterval(10)
        while second == first, Date() < deadline {
            usleep(200_000)
            second = samples.value as? String
        }

        XCTAssertNotNil(second)
        XCTAssertNotEqual(
            first, second,
            "The detail pane kept the previous workout's series after the selection changed."
        )
    }

    /// The detail column starts hidden and appears on the first selection.
    ///
    /// Worth a test because the alternative is a third of the window given over to "No Workout
    /// Selected" at launch, and because hiding it without revealing it on selection would look
    /// like clicking a row did nothing.
    @MainActor
    func testDetailPaneIsHiddenUntilSomethingIsSelected() throws {
        let app = launchSeeded()
        let table = app.outlines["WorkoutTable"]
        XCTAssertTrue(table.waitForExistence(timeout: 15))

        XCTAssertFalse(
            app.staticTexts["No Workout Selected"].exists,
            "The detail column should not be taking space before there is anything to show."
        )

        table.cells.element(boundBy: 0).click()
        XCTAssertTrue(
            app.staticTexts.containing(
                NSPredicate(format: "value CONTAINS[c] 'Duration'")
            ).firstMatch.waitForExistence(timeout: 10),
            "Selecting a row must reveal the detail column."
        )
    }

    /// The inspector's toolbar toggle closes it, and the close is **obeyed**.
    ///
    /// Both halves matter. Before the toggle the pane could only be dismissed from the menu, so it
    /// read as undismissable; and had the old "reopen on the next selection" rule survived, the
    /// close would have been undone by the very next click, which is the same thing from the
    /// user's side.
    @MainActor
    func testTheInspectorCanBeClosedAndStaysClosed() throws {
        let app = launchSeeded()
        let table = app.outlines["WorkoutTable"]
        XCTAssertTrue(table.waitForExistence(timeout: 15))

        table.cells.element(boundBy: 0).click()
        let detail = app.staticTexts.containing(NSPredicate(format: "value CONTAINS[c] 'Duration'"))
        XCTAssertTrue(detail.firstMatch.waitForExistence(timeout: 10),
                      "Selecting a row should have revealed the inspector.")

        let toggle = app.checkBoxes["Inspector"].exists
            ? app.checkBoxes["Inspector"] : app.buttons["Inspector"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5),
                      "The toolbar has no Inspector control, so the pane can't be closed.")
        toggle.click()

        // `waitForNonExistence` rather than a bare check: the pane animates out.
        XCTAssertTrue(detail.firstMatch.waitForNonExistence(timeout: 10),
                      "The toolbar toggle didn't close the inspector.")

        table.cells.element(boundBy: 1).click()
        XCTAssertFalse(detail.firstMatch.waitForExistence(timeout: 3),
                       "Selecting another row reopened the inspector after it was closed.")

        toggle.click()
        XCTAssertTrue(detail.firstMatch.waitForExistence(timeout: 10),
                      "The toggle should reopen the inspector it closed.")
    }

    /// The sidebar keeps the same inset from the window's left edge whether or not the inspector
    /// is open, and the panes never spill past the window.
    ///
    /// The bug this pins: with the inspector open the three panes laid out 1,318pt wide in a
    /// 1,300pt window, and SwiftUI centres oversized content — so 9pt was clipped off each side,
    /// which the user saw as the sidebar losing its inset. Cause was the inspector opening at its
    /// 560pt ideal rather than shrinking to fit.
    ///
    /// Checked twice: at the default width, and after dragging the window as narrow as it will go,
    /// where the minimum-width guard has to hold the line instead.
    @MainActor
    func testTheInspectorNeverPushesThePanesPastTheWindow() throws {
        let app = launchSeeded()
        let table = app.outlines["WorkoutTable"]
        let sidebar = app.outlines["Sidebar"]
        let window = app.windows.firstMatch
        XCTAssertTrue(table.waitForExistence(timeout: 15))

        // The window's frame is autosaved into the app's real defaults, which UI tests share, so a
        // width left narrow would leak into later tests and into the user's own window. Restored in
        // a teardown block so that a failing assertion can't skip it — which it did, once.
        let launchWidth = window.frame.width
        addTeardownBlock { @MainActor in
            let shortfall = launchWidth - window.frame.width
            guard shortfall > 1 else { return }
            let edge = window.coordinate(withNormalizedOffset: CGVector(dx: 1, dy: 0.5))
                .withOffset(CGVector(dx: -1, dy: 0))
            edge.press(forDuration: 0.3, thenDragTo: edge.withOffset(CGVector(dx: shortfall, dy: 0)))
            // Time for AppKit to autosave the restored frame before the app is terminated; one
            // run with less left 1,200 saved instead of 1,300.
            Thread.sleep(forTimeInterval: 1.5)
        }

        func assertContained(_ when: String, inset expected: CGFloat? = nil) -> CGFloat {
            let inset = sidebar.frame.minX - window.frame.minX
            XCTAssertGreaterThan(inset, 0, "The sidebar is clipped by the window edge \(when).")
            for group in window.splitGroups.allElementsBoundByIndex {
                XCTAssertLessThanOrEqual(group.frame.width, window.frame.width + 0.5,
                                         "Panes are wider than the window \(when).")
            }
            if let expected {
                XCTAssertEqual(inset, expected, accuracy: 0.5,
                               "The sidebar's inset changed \(when).")
            }
            return inset
        }

        let inset = assertContained("with the inspector closed")
        table.cells.element(boundBy: 0).click()
        let detail = app.staticTexts.containing(NSPredicate(format: "value CONTAINS[c] 'Duration'"))
        XCTAssertTrue(detail.firstMatch.waitForExistence(timeout: 10))
        Thread.sleep(forTimeInterval: 1)
        _ = assertContained("with the inspector open", inset: inset)

        // As narrow as the window allows, with the inspector still open.
        let rightEdge = window.coordinate(withNormalizedOffset: CGVector(dx: 1, dy: 0.5))
            .withOffset(CGVector(dx: -1, dy: 0))
        let widthBefore = window.frame.width
        rightEdge.press(forDuration: 0.3, thenDragTo: rightEdge.withOffset(CGVector(dx: -600, dy: 0)))
        Thread.sleep(forTimeInterval: 1)
        let narrowed = window.frame.width
        XCTAssertLessThan(narrowed, widthBefore, "The drag didn't resize the window, so the "
                          + "narrow case went untested.")
        _ = assertContained("in the narrowest window", inset: inset)
    }

    /// Opening the inspector must not cost the sidebar.
    ///
    /// The regression test for the collapse that broke every other sidebar test: the inspector
    /// squeezed the sidebar out, and AppKit then saved that as if it had been chosen, so later
    /// launches opened without one. Stating `columnVisibility` fixed both.
    ///
    /// Asserts on the sidebar's **width**, not on `exists` — a squeezed pane stays in the
    /// accessibility tree, so an existence check passed throughout the original bug.
    @MainActor
    func testOpeningTheInspectorKeepsTheSidebar() throws {
        let app = launchSeeded()
        let table = app.outlines["WorkoutTable"]
        let sidebar = app.outlines["Sidebar"]
        XCTAssertTrue(table.waitForExistence(timeout: 15))
        XCTAssertTrue(sidebar.waitForExistence(timeout: 5))
        let sidebarBefore = sidebar.frame.width
        XCTAssertGreaterThan(sidebarBefore, 100, "The sidebar started collapsed.")

        table.cells.element(boundBy: 0).click()
        XCTAssertTrue(
            app.staticTexts.containing(NSPredicate(format: "value CONTAINS[c] 'Duration'"))
                .firstMatch.waitForExistence(timeout: 10)
        )

        XCTAssertEqual(
            sidebar.frame.width, sidebarBefore, accuracy: 1,
            "Opening the inspector squeezed the sidebar. The table is what should give way."
        )
    }

    /// The Place column's three states, which are three different claims.
    ///
    /// Geocoding is disabled under `--ui-testing`, so this is deterministic and offline: no
    /// workout has a name, and the column must still distinguish "indoor, so never" from "not
    /// yet". Conflating those is the same mistake the thumbnail placeholder made, where every
    /// outdoor ride was labelled indoor.
    @MainActor
    func testPlaceColumnSeparatesIndoorFromNotYetKnown() throws {
        let app = launchSeeded()
        XCTAssertTrue(app.outlines["WorkoutTable"].waitForExistence(timeout: 15))

        XCTAssertTrue(
            app.staticTexts["Indoor"].firstMatch.waitForExistence(timeout: 10),
            "An indoor workout has no route and so can never have a place — say so."
        )
        // And an outdoor workout without a resolved name shows the em dash instead.
        XCTAssertTrue(
            app.staticTexts.containing(
                NSPredicate(format: "value == %@", "\u{2014}")
            ).firstMatch.exists,
            "An outdoor workout awaiting geocoding is unknown, not indoor."
        )
    }

    /// Multi-select and the aggregate summary — the reason the table exists — had no coverage.
    ///
    /// Uses the system's ⌘A, which SwiftUI routes to the table's selection binding once a row has
    /// been clicked and the table has focus. This previously typed ⌘⇧A for a custom command; that
    /// shortcut is taken globally by Zoom, so the keystroke never reached the app.
    /// Batch tagging — the reason tags are worth having. Select everything, tag it from the
    /// context menu, and the tag must appear in the sidebar covering every workout.
    @MainActor
    func testTaggingASelectionTagsEveryWorkout() throws {
        let app = launchSeeded()
        let table = app.outlines["WorkoutTable"]
        XCTAssertTrue(table.waitForExistence(timeout: 15))

        table.cells.element(boundBy: 0).click()
        app.typeKey("a", modifierFlags: [.command])
        table.cells.element(boundBy: 0).rightClick()

        let tagsMenu = app.menuItems["Tags"]
        XCTAssertTrue(tagsMenu.waitForExistence(timeout: 5), "The context menu has no Tags submenu.")
        tagsMenu.hover()
        let newTag = app.menuItems["New Tag…"]
        XCTAssertTrue(newTag.waitForExistence(timeout: 5))
        newTag.click()

        let field = app.dialogs.textFields.firstMatch.exists
            ? app.dialogs.textFields.firstMatch : app.sheets.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5), "No name field for the new tag.")
        field.click()
        field.typeText("With Kid")
        let add = app.sheets.buttons["Add"].exists ? app.sheets.buttons["Add"] : app.dialogs.buttons["Add"]
        XCTAssertTrue(add.waitForExistence(timeout: 3), "No Add button")
        add.click()

        // Verified through search rather than the sidebar's Tags section: with rows selected the
        // inspector opens, and at the default width SwiftUI collapses the sidebar to make room —
        // so the sidebar isn't in the window to read. Search for the tag must find all 40.
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.click()
        search.typeText("With Kid")
        XCTAssertTrue(
            app.staticTexts.containing(NSPredicate(format: "value CONTAINS %@", "40 workouts"))
                .firstMatch.waitForExistence(timeout: 10),
            "Searching the new tag should find all 40 tagged workouts."
        )
    }

    @MainActor
    func testSelectAllShowsAnAggregateSummary() throws {
        let app = launchSeeded()
        let table = app.outlines["WorkoutTable"]
        XCTAssertTrue(table.waitForExistence(timeout: 15))

        table.cells.element(boundBy: 0).click()
        app.typeKey("a", modifierFlags: [.command])

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
