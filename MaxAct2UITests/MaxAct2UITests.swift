import AppKit
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
    func launchMaxAct(seed: Int? = nil, extraArguments: [String] = []) -> XCUIApplication {
        let app = XCUIApplication(bundleIdentifier: "com.swiatlowski.MaxAct")
        app.launchArguments = ["-ApplePersistenceIgnoreState", "YES", "--ui-testing"] + extraArguments
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
        // Both Strava commands, which share the letter U (⇧⌘U upload, ⌥⌘U check).
        XCTAssertTrue(app.menuItems["Upload Selection to Strava"].exists)
        XCTAssertTrue(app.menuItems["Check Strava for Existing Activities"].exists)
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

    /// Phase 8: a first launch with nothing configured opens the welcome sheet, whose Test
    /// Connection names the problem — here, this Mac, where no server is running.
    @MainActor
    func testTheWelcomeSheetGuidesAFirstLaunchAndTestsTheConnection() throws {
        let app = launchMaxAct(extraArguments: ["--ui-testing-welcome"])
        let sheet = app.sheets.firstMatch
        XCTAssertTrue(sheet.waitForExistence(timeout: 10), "A first launch should show the welcome sheet.")
        XCTAssertTrue(sheet.staticTexts["Welcome to MaxAct"].exists)

        let test = sheet.buttons["Test Connection"]
        XCTAssertFalse(test.isEnabled, "Nothing to test until an address and token are entered.")
        let address = sheet.textFields.element(boundBy: 0)
        address.click()
        address.typeText("127.0.0.1")
        let token = sheet.textFields.element(boundBy: 1)
        token.click()
        token.typeText("irrelevant")
        XCTAssertTrue(test.isEnabled)
        test.click()

        // Found by its text: inside a `Label`, the identifier on the text isn't exposed.
        let result = sheet.staticTexts.containing(NSPredicate(format: "value CONTAINS %@", "server isn't running")).firstMatch
        if !result.waitForExistence(timeout: 20) {
            print("WELCOME SHEET:\n\(sheet.debugDescription)")
            XCTFail("Test Connection should report that the server isn't running.")
        }

        sheet.buttons["Later"].click()
        XCTAssertTrue(sheet.waitForNonExistence(timeout: 5))
    }

    /// Phase 8: Help ▸ Getting Started reopens the welcome sheet at any time.
    @MainActor
    func testHelpReopensTheWelcomeSheet() throws {
        let app = launchApp()
        XCTAssertFalse(app.sheets.firstMatch.exists, "UI tests don't get the welcome sheet unasked.")
        app.menuBars.menuBarItems["Help"].click()
        app.menuItems["Getting Started with MaxAct…"].click()
        XCTAssertTrue(app.sheets.firstMatch.staticTexts["Welcome to MaxAct"].waitForExistence(timeout: 5))
    }

    /// Phase 8: a refused connection names its cause.
    @MainActor
    func testARefusedConnectionSaysTheServerIsntRunning() throws {
        let app = launchApp()
        app.buttons["Sync"].click()

        let address = app.textFields.element(boundBy: 0)
        XCTAssertTrue(address.waitForExistence(timeout: 5))
        address.click()
        address.typeText("127.0.0.1")     // this Mac, where nothing listens on 9000: refused at once
        let token = app.textFields.element(boundBy: 1)
        token.click()
        token.typeText("irrelevant")
        app.buttons["Start Sync"].click()

        // Phase 8: a refused connection is "the server isn't running", not a generic network error.
        let banner = app.staticTexts["SyncBannerMessage"]
        XCTAssertTrue(banner.waitForExistence(timeout: 15), "No sync banner appeared.")
        let refused = NSPredicate(format: "value CONTAINS %@", "server isn't running")
        XCTAssertEqual(XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: refused, object: banner)], timeout: 15),
                       .completed, "The banner should say the server isn't running; it says '\(banner.value ?? "")'.")
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

    /// Issue 8a/8b/8d: over the statistics the inspector is drawn *on top of* their column, so
    /// nothing is cut off; a personal best opens there; and the statistics reflow, then scroll, as
    /// the window narrows.
    ///
    /// Before: the window's real inspector opened beside the statistics, SwiftUI pinned the
    /// statistics column at its current width, and the panes ran off both edges of the window —
    /// the inspector 40pt wide, the sidebar cut off.
    @MainActor
    func testStatisticsShowTheInspectorOverThem() throws {
        let app = launchSeeded()
        let window = app.windows.firstMatch
        let sidebar = app.outlines["Sidebar"]
        XCTAssertTrue(sidebar.waitForExistence(timeout: 15))

        let launchWidth = window.frame.width
        addTeardownBlock { @MainActor in
            let shortfall = launchWidth - window.frame.width
            guard abs(shortfall) > 1 else { return }
            let edge = window.coordinate(withNormalizedOffset: CGVector(dx: 1, dy: 0.5))
                .withOffset(CGVector(dx: -1, dy: 0))
            edge.press(forDuration: 0.3, thenDragTo: edge.withOffset(CGVector(dx: shortfall, dy: 0)))
            Thread.sleep(forTimeInterval: 1.5)
        }

        func capture(_ name: String) {
            let attachment = XCTAttachment(screenshot: window.screenshot())
            attachment.name = name
            attachment.lifetime = .keepAlways
            add(attachment)
        }

        sidebar.staticTexts.containing(NSPredicate(format: "value == 'Statistics' OR label == 'Statistics'"))
            .firstMatch.click()
        let scroll = app.scrollViews["StatisticsScroll"]
        XCTAssertTrue(scroll.waitForExistence(timeout: 10))
        let inspector = app.descendants(matching: .any)["StatisticsInspector"].firstMatch

        /// Nothing cut off by the window; the inspector, when open, at its minimum width or more
        /// and flush with the statistics; everything wide inside the statistics while they're at
        /// least their minimum width (below it they scroll sideways, by design).
        func assertLaidOut(_ when: String, inspectorOpen: Bool) {
            continueAfterFailure = true
            defer { continueAfterFailure = false }
            let area = scroll.frame
            print("STATS \(when): window \(window.frame.minX)…\(window.frame.maxX) "
                  + "sidebar \(sidebar.frame.minX)…\(sidebar.frame.maxX) statistics \(area.minX)…\(area.maxX) "
                  + "inspector \(inspector.exists ? "\(inspector.frame.minX)…\(inspector.frame.maxX)" : "none")")
            XCTAssertGreaterThanOrEqual(sidebar.frame.minX, window.frame.minX,
                                        "The sidebar is cut off by the window's left edge \(when).")
            XCTAssertEqual(inspector.exists, inspectorOpen, "The inspector's state is wrong \(when).")
            // The panel's identifier lands on an inner element, so measure the panel by its edges:
            // it runs from where the statistics end to the window's edge, and contains its content.
            let panelWidth = window.frame.maxX - area.maxX
            if inspectorOpen {
                XCTAssertGreaterThanOrEqual(panelWidth, 439, "The inspector is squeezed \(when).")
                XCTAssertGreaterThanOrEqual(inspector.frame.minX, area.maxX - 0.5,
                                            "The inspector overlaps the statistics \(when).")
                XCTAssertLessThanOrEqual(inspector.frame.maxX, window.frame.maxX + 0.5,
                                         "The inspector runs off the window \(when).")
            } else {
                XCTAssertEqual(panelWidth, 0, accuracy: 2, "Something sits beside the statistics \(when).")
            }
            guard area.width >= 480 else { return }
            let wide: [(String, XCUIElement)] = [
                ("period picker", app.radioGroups["Period"]),
                ("heat map", app.otherElements["Training calendar, past year"]),
            ] + app.groups.matching(NSPredicate(format: "label ENDSWITH 'personal bests'"))
                .allElementsBoundByIndex.map { ("best card", $0) }
            for (name, element) in wide where element.exists && element.isHittable {
                XCTAssertLessThanOrEqual(element.frame.maxX, area.maxX + 0.5,
                                         "The \(name) runs past the statistics' right edge \(when).")
            }
        }
        assertLaidOut("on arrival", inspectorOpen: false)

        // A personal best opens its workout in the inspector, over the statistics.
        app.links["PersonalBest"].firstMatch.click()
        XCTAssertTrue(inspector.waitForExistence(timeout: 10), "A personal best should open the inspector.")
        XCTAssertTrue(inspector.staticTexts.containing(NSPredicate(format: "value CONTAINS[c] 'Duration'"))
            .firstMatch.waitForExistence(timeout: 10), "The inspector should show the workout.")
        Thread.sleep(forTimeInterval: 0.5)
        assertLaidOut("with a best open", inspectorOpen: true)
        capture("8d-1-inspector-over-statistics")

        // ⌃⌘I closes and reopens it here, as beside the list.
        app.typeKey("i", modifierFlags: [.control, .command])
        XCTAssertTrue(inspector.waitForNonExistence(timeout: 5), "⌃⌘I should close the inspector.")
        assertLaidOut("after ⌃⌘I", inspectorOpen: false)
        app.typeKey("i", modifierFlags: [.control, .command])
        XCTAssertTrue(inspector.waitForExistence(timeout: 5), "⌃⌘I should reopen the inspector.")
        Thread.sleep(forTimeInterval: 0.5)

        // As narrow as the window goes, inspector open: nothing cut off; the statistics scroll.
        let edge = window.coordinate(withNormalizedOffset: CGVector(dx: 1, dy: 0.5))
            .withOffset(CGVector(dx: -1, dy: 0))
        let widthBefore = window.frame.width
        edge.press(forDuration: 0.3, thenDragTo: edge.withOffset(CGVector(dx: -800, dy: 0)))
        Thread.sleep(forTimeInterval: 1)
        XCTAssertLessThan(window.frame.width, widthBefore, "The window didn't narrow, so the narrow case went untested.")
        assertLaidOut("in the narrowest window", inspectorOpen: true)
        capture("8d-2-narrowest-window")

        // Back on the list, the system inspector shows the same workout.
        sidebar.staticTexts.containing(NSPredicate(format: "label BEGINSWITH 'All Workouts'")).firstMatch.click()
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "value CONTAINS[c] 'Duration'"))
            .firstMatch.waitForExistence(timeout: 10), "The inspector should carry over to the list.")
    }

    /// Pointing at a chart highlights the same moment on the map; clicking empty map clears it.
    ///
    /// Observed through the map marker, which carries an identifier. The charts' spoken values
    /// can't be read here: macOS exposes a chart with `accessibilityElement(children: .ignore)` as
    /// a plain group, and groups carry no AXValue — measured, the value came back empty.
    @MainActor
    func testPointingAtAChartHighlightsTheMap() throws {
        let app = launchSeeded()
        let table = app.outlines["WorkoutTable"]
        XCTAssertTrue(table.waitForExistence(timeout: 15))
        table.cells.element(boundBy: 0).click()

        let heartRate = app.otherElements.matching(NSPredicate(format: "label == 'Heart Rate'")).firstMatch
        XCTAssertTrue(heartRate.waitForExistence(timeout: 15), "No heart-rate chart.")
        let marker = app.descendants(matching: .any)["RouteHighlight"]
        XCTAssertFalse(marker.exists, "Nothing should be highlighted before pointing at anything.")

        heartRate.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).hover()
        XCTAssertTrue(marker.waitForExistence(timeout: 5),
                      "Pointing at a chart didn't put a marker on the map.")
        let markerCentre = CGVector(dx: marker.frame.midX, dy: marker.frame.midY)

        // Any element type: the map is exposed as a map element, not a group (measured).
        let map = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label BEGINSWITH 'Route map with'")).firstMatch
        XCTAssertTrue(map.exists)
        let origin = app.windows.firstMatch.coordinate(withNormalizedOffset: .zero)
        let windowOrigin = app.windows.firstMatch.frame.origin

        // The other direction: click the route — exactly where the marker was, so on the route by
        // construction — and the highlight must be set by the map, not left over from the hover.
        let onRoute = origin.withOffset(CGVector(dx: markerCentre.dx - windowOrigin.x,
                                                 dy: markerCentre.dy - windowOrigin.y))
        onRoute.click()
        XCTAssertTrue(marker.waitForExistence(timeout: 5),
                      "Clicking the route didn't highlight that moment.")

        // Empty map, well away from a route that loops round the middle, clears it.
        map.coordinate(withNormalizedOffset: CGVector(dx: 0.03, dy: 0.05)).click()
        XCTAssertTrue(marker.waitForNonExistence(timeout: 5),
                      "Clicking empty map should clear the highlight, not jump to the nearest point.")
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

    /// Issue 15: Training Load asks for the heart-rate details on first use, then shows Fitness,
    /// Fatigue and Form. The test's curve choice is arbitrary — it only exercises the layout.
    @MainActor
    func testTrainingLoadAsksForHeartRateThenShowsFitness() throws {
        let app = launchSeeded()
        let sidebar = app.outlines["Sidebar"]
        XCTAssertTrue(sidebar.waitForExistence(timeout: 15))
        sidebar.staticTexts.containing(NSPredicate(format: "value == 'Statistics' OR label == 'Statistics'"))
            .firstMatch.click()

        let prompt = app.staticTexts["Set your heart-rate details to see Fitness, Fatigue and Form."]
        XCTAssertTrue(prompt.waitForExistence(timeout: 10), "Training Load should ask first.")
        let scroll = app.scrollViews["StatisticsScroll"]
        for _ in 0..<10 where !prompt.isHittable { scroll.scroll(byDeltaX: 0, deltaY: -300) }

        let fields = app.textFields.matching(NSPredicate(format: "placeholderValue == 'required'"))
        let resting = fields.element(boundBy: 0), maximum = fields.element(boundBy: 1)
        resting.click(); resting.typeText("55\t")
        maximum.click(); maximum.typeText("190\t")
        app.popUpButtons["Effort curve"].click()
        app.menuItems["Male (1.92)"].click()

        XCTAssertTrue(app.staticTexts["Fitness"].waitForExistence(timeout: 5), "Fitness should appear once set.")
        XCTAssertTrue(app.staticTexts["Fatigue"].exists)
        XCTAssertFalse(prompt.exists, "The prompt goes once the details are set.")
        let attachment = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        attachment.name = "15-training-load"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// Phase 8: an empty filter says what it means; only an actual search gets "No Results".
    /// The seed has no failed uploads, so Upload Failed is empty.
    @MainActor
    func testEmptyFiltersSayWhatTheyMean() throws {
        let app = launchSeeded()
        let sidebar = app.outlines["Sidebar"]
        XCTAssertTrue(sidebar.waitForExistence(timeout: 15))

        sidebar.staticTexts.containing(NSPredicate(format: "label BEGINSWITH 'Upload Failed'")).firstMatch.click()
        XCTAssertTrue(app.staticTexts["No Failed Uploads"].waitForExistence(timeout: 5),
                      "An empty Upload Failed should say there are none.")
        XCTAssertFalse(app.staticTexts.containing(NSPredicate(format: "value BEGINSWITH 'No Results'")).firstMatch.exists,
                       "Nothing was searched, so it mustn't say 'No Results'.")

        let search = app.searchFields.firstMatch
        search.click()
        search.typeText("zzzz")
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "value BEGINSWITH 'No Results'"))
            .firstMatch.waitForExistence(timeout: 5), "A search with no matches says so.")
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

    /// Issue 8: the Statistics row swaps the table for a summary, and a personal best leads back
    /// to its workout.
    ///
    /// The seed is 40 daily workouts ending 9 October 2025, so "this year" is empty and 2025 plays
    /// "last year" — the summary must cope with a current period that has nothing in it.
    @MainActor
    func testStatisticsSummariseTheLibraryAndLeadBackToAWorkout() throws {
        let app = launchSeeded()
        let sidebar = app.outlines["Sidebar"]
        XCTAssertTrue(sidebar.waitForExistence(timeout: 15))
        let row = sidebar.staticTexts.containing(NSPredicate(format: "value == 'Statistics' OR label == 'Statistics'")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.click()

        for heading in ["Totals", "History", "Year by Year", "Consistency", "Personal Bests"] {
            XCTAssertTrue(
                app.staticTexts.containing(NSPredicate(format: "value == %@ OR label == %@", heading, heading))
                    .firstMatch.waitForExistence(timeout: 10),
                "The statistics view should have a \(heading) section."
            )
        }
        XCTAssertFalse(app.outlines["WorkoutTable"].exists, "Statistics replace the table.")

        // Pointing at an earlier bar moves the caption off the current period.
        let focus = app.staticTexts["HistoryFocus"]
        XCTAssertTrue(focus.waitForExistence(timeout: 5))
        let current = focus.value as? String
        // The chart is one merged element, which keeps its label but not an identifier.
        let chart = app.otherElements.matching(NSPredicate(format: "label CONTAINS ' per '")).firstMatch
        XCTAssertTrue(chart.exists)
        chart.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.5)).hover()
        let moved = NSPredicate { _, _ in (focus.value as? String) != current }
        XCTAssertEqual(XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: moved, object: nil)], timeout: 5),
                       .completed, "Hovering the history chart should describe the bar under the pointer.")

        // A personal best opens its workout in the inspector, without leaving the statistics.
        let best = app.links["PersonalBest"].firstMatch  // `.link` style: a link, not a button
        best.click()
        XCTAssertTrue(
            app.staticTexts.containing(NSPredicate(format: "value CONTAINS[c] 'Duration'"))
                .firstMatch.waitForExistence(timeout: 10),
            "Clicking a personal best should show that workout's details."
        )
        XCTAssertFalse(app.outlines["WorkoutTable"].exists)
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


/// Layout checked against a **copy of a real library** rather than seeded data — real place names,
/// real numbers, real lengths. Skipped unless a copy has been placed in the app's temporary
/// directory (`<container>/Data/tmp/ui-testing-copy/`), which is done by hand and removed after.
///
/// Isolated like every UI test: in-memory secrets, no geocoding, throwaway settings. Screenshots
/// are of the MaxAct window only, never the screen, and are kept in the test result for review.
final class RealContentUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testInspectorLayoutWithRealContent() throws {
        let app = launchMaxAct(extraArguments: ["--ui-testing-real-copy"])
        let window = app.windows.firstMatch
        let table = app.outlines["WorkoutTable"]
        guard table.waitForExistence(timeout: 15) else {
            throw XCTSkip("No real-library copy in place; nothing to measure.")
        }

        let launchWidth = window.frame.width
        addTeardownBlock { @MainActor in
            let excess = window.frame.width - launchWidth
            guard abs(excess) > 1 else { return }
            let edge = window.coordinate(withNormalizedOffset: CGVector(dx: 1, dy: 0.5))
                .withOffset(CGVector(dx: -1, dy: 0))
            edge.press(forDuration: 0.3, thenDragTo: edge.withOffset(CGVector(dx: -excess, dy: 0)))
            Thread.sleep(forTimeInterval: 1.5)
        }

        func capture(_ name: String) {
            Thread.sleep(forTimeInterval: 1)
            print("REAL \(name): window \(window.frame.width) table \(table.frame.width)")
            let attachment = XCTAttachment(screenshot: window.screenshot())
            attachment.name = name
            attachment.lifetime = .keepAlways
            add(attachment)
        }

        capture("1-inspector-closed")
        table.cells.element(boundBy: 0).click()
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "value CONTAINS[c] 'Duration'"))
            .firstMatch.waitForExistence(timeout: 10))
        capture("2-inspector-open-default-width")

        // The charts sit below the map: scroll the detail pane to them, to check they line up.
        // On a ride, whose speed axis has the widest labels ("36.0 km/h") — a walk's pace labels
        // happened to match heart rate's width closely enough to hide a misalignment once.
        let ride = table.staticTexts["Cycling"].firstMatch
        if ride.exists { ride.click() }
        let heartRate = app.otherElements.matching(NSPredicate(format: "label == 'Heart Rate'")).firstMatch
        if heartRate.waitForExistence(timeout: 5) {
            // Scrolling over the chart scrolls the detail pane that contains it.
            heartRate.scroll(byDeltaX: 0, deltaY: -600)
            heartRate.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).hover()
            capture("2b-charts-aligned")
        }

        let edge = window.coordinate(withNormalizedOffset: CGVector(dx: 1, dy: 0.5))
            .withOffset(CGVector(dx: -1, dy: 0))
        edge.press(forDuration: 0.3, thenDragTo: edge.withOffset(CGVector(dx: 300, dy: 0)))
        capture("3-inspector-open-300pt-wider")
    }

    /// Issue 8: the statistics view over the real library, top to bottom, for checking by eye.
    @MainActor
    func testStatisticsWithRealContent() throws {
        let app = launchMaxAct(extraArguments: ["--ui-testing-real-copy"])
        let window = app.windows.firstMatch
        let sidebar = app.outlines["Sidebar"]
        guard app.outlines["WorkoutTable"].waitForExistence(timeout: 15) else {
            throw XCTSkip("No real-library copy in place; nothing to measure.")
        }
        sidebar.staticTexts.containing(NSPredicate(format: "value == 'Statistics' OR label == 'Statistics'"))
            .firstMatch.click()
        XCTAssertTrue(app.staticTexts["HistoryFocus"].waitForExistence(timeout: 10))

        for index in 1...4 {
            Thread.sleep(forTimeInterval: 1)
            let attachment = XCTAttachment(screenshot: window.screenshot())
            attachment.name = "s\(index)-statistics"
            attachment.lifetime = .keepAlways
            add(attachment)
            // Over the empty margin beside the statistics: a chart under the pointer takes the
            // scroll for itself.
            window.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.5)).scroll(byDeltaX: 0, deltaY: -450)
        }
    }
}
