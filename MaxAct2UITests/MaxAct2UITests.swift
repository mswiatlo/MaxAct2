import AppKit
import XCTest

/// Launch and structure checks.
///
/// The app is launched by bundle identifier rather than via `XCUIApplication()`, because
/// `TEST_TARGET_NAME` — the setting that supplies the implicit target application — is not
/// writable through the available tooling. The scheme's build action builds the app for testing,
/// so the bundle is present by the time this runs.
///
/// These launch with an empty, in-memory library (`--ui-testing`), so they cover the app's chrome:
/// menus, the sync panel, settings and the welcome sheet. Tests that need workouts are in
/// `SeededTableUITests`.
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

    /// Launched with a connection already set up, over plain HTTP (issue 49: the sync panel has no
    /// fields to type it into).
    @MainActor
    private func launchConfigured(host: String) -> XCUIApplication {
        launchMaxAct(defaults: ["syncHost": host], extraArguments: ["--ui-testing-token=irrelevant"])
    }

    /// Opens Settings and waits for its address field.
    @MainActor
    private func openSettings(_ app: XCUIApplication) -> XCUIElement {
        app.typeKey(",", modifierFlags: .command)
        let address = app.textFields["SettingsHost"]
        if !address.waitForExistence(timeout: 5) {
            print("SETTINGS TREE:\n\(app.windows.firstMatch.debugDescription)")
            XCTFail("Settings has no address field.")
        }
        return address
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

        // Unconfigured, the panel says so, says exactly what's missing, and offers the way there.
        XCTAssertTrue(
            app.staticTexts.containing(
                NSPredicate(format: "value CONTAINS[c] 'Health Auto Export'")
            ).firstMatch.waitForExistence(timeout: 5),
            "Sync panel should say the connection to Health Auto Export needs setting up."
        )
        XCTAssertTrue(app.staticTexts["Enter the address and token shown on the Server screen."].exists,
                      "Sync panel should say what's missing, not just that something is.")
        XCTAssertTrue(app.buttons["Connection Settings…"].exists, "Sync panel should offer a route to Settings.")
    }

    /// Issue 49: the connection is edited in Settings only. The panel has no fields, and its
    /// button opens Settings at them.
    @MainActor
    func testTheSyncPanelLeavesTheConnectionToSettings() throws {
        let app = launchApp()
        app.buttons["Sync"].click()
        let settingsButton = app.buttons["Connection Settings…"]
        XCTAssertTrue(settingsButton.waitForExistence(timeout: 5))
        let panel = app.popovers.firstMatch
        XCTAssertTrue(panel.exists)
        XCTAssertEqual(panel.textFields.count, 0, "The panel shouldn't edit the connection.")
        XCTAssertEqual(panel.secureTextFields.count, 0, "The panel shouldn't take the token.")
        XCTAssertTrue(app.buttons["Start Sync"].exists, "The panel must still offer a way to start syncing.")

        settingsButton.click()
        XCTAssertTrue(app.textFields["SettingsHost"].waitForExistence(timeout: 5),
                      "Connection Settings… should open Settings at the connection fields.")
        XCTAssertTrue(app.buttons["Test Connection"].exists, "Settings should offer Test Connection.")
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

    /// Typing an address and token in Settings is enough to make syncing possible, and the
    /// panel says where it will connect — the old dead end was a panel that never changed.
    @MainActor
    func testEnteringAnAddressEnablesSyncing() throws {
        let app = launchApp()
        let address = openSettings(app)
        address.click()
        address.typeText("10.0.0.158")
        let token = app.secureTextFields.firstMatch   // hidden (issue 47)
        token.click()
        token.typeText("test-token")
        app.typeKey("w", modifierFlags: .command)

        app.buttons["Sync"].click()
        let startSync = app.buttons["Start Sync"]
        XCTAssertTrue(startSync.waitForExistence(timeout: 5))
        XCTAssertTrue(startSync.isEnabled, "With an address and a token entered, Start Sync must be available.")
        XCTAssertTrue(app.staticTexts["Connects to http://10.0.0.158:9000/mcp"].exists,
                      "The panel should say where it will connect.")
    }

    /// Follow-up from 49: every control in Settings and the welcome sheet carries its own name. In a
    /// grouped form the title is drawn as separate text, and the fields exposed only their prompt
    /// ("required") — what VoiceOver would announce. Queried by label, not identifier.
    @MainActor
    func testSettingsControlsAreNamed() throws {
        let app = launchApp()
        _ = openSettings(app)
        func named(_ query: XCUIElementQuery, _ name: String) -> Bool {
            query.matching(NSPredicate(format: "label == %@", name)).firstMatch.exists
        }
        var missing: [String] = []
        for (query, name) in [(app.textFields, "iPhone address"), (app.secureTextFields, "Bearer token"),
                              (app.switches, "Use HTTPS"), (app.textFields, "Client ID"),
                              (app.secureTextFields, "Client secret"), (app.popUpButtons, "Route colour"),
                              (app.textFields, "Resting heart rate"), (app.textFields, "Maximum heart rate"),
                              (app.popUpButtons, "Effort curve")] where !named(query, name) {
            missing.append(name)
        }
        XCTAssertEqual(missing, [], "Unnamed in Settings")

        app.typeKey("w", modifierFlags: .command)
        app.menuBars.menuBarItems["Help"].click()
        app.menuItems["Getting Started with MaxAct…"].click()
        let sheet = app.sheets.firstMatch
        XCTAssertTrue(sheet.waitForExistence(timeout: 5))
        missing = [(sheet.textFields, "iPhone address"), (sheet.secureTextFields, "Token"), (sheet.switches, "Use HTTPS")]
            .filter { !named($0.0, $0.1) }.map(\.1)
        XCTAssertEqual(missing, [], "Unnamed in the welcome sheet")
    }

    /// Issue 48: HTTPS can't sync until HAE's certificate is loaded, and with HTTPS off Settings
    /// says that's less safe. A switch, as in the welcome sheet (49).
    @MainActor
    func testHTTPSNeedsTheCertificateBeforeSyncing() throws {
        let app = launchConfigured(host: "10.0.0.158")
        _ = openSettings(app)
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "value BEGINSWITH %@", "HTTPS is off")).firstMatch.exists)
        let https = app.switches["UseHTTPS"]
        XCTAssertTrue(https.exists, "Use HTTPS should be a switch.")
        https.click()
        XCTAssertTrue(app.buttons["Load Certificate…"].waitForExistence(timeout: 3))
        app.typeKey("w", modifierFlags: .command)

        app.buttons["Sync"].click()
        let startSync = app.buttons["Start Sync"]
        XCTAssertTrue(startSync.waitForExistence(timeout: 5))
        XCTAssertFalse(startSync.isEnabled, "HTTPS without the CA can't sync.")
        XCTAssertTrue(app.staticTexts["HTTPS needs Health Auto Export's certificate."].exists)
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
        let token = sheet.secureTextFields.firstMatch   // hidden (issue 47)
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

    /// Issue 17: the sync panel can import one chosen month, and won't offer one still to come.
    @MainActor
    func testTheSyncPanelImportsASpecificMonth() throws {
        let app = launchConfigured(host: "10.255.255.1")
        app.buttons["Sync"].click()
        XCTAssertTrue(app.popUpButtons["Import"].waitForExistence(timeout: 5))
        app.popUpButtons["Import"].click()
        app.menuItems["A specific month…"].click()
        let month = app.popUpButtons["Month"]
        XCTAssertTrue(month.waitForExistence(timeout: 5), "Choosing a specific month should offer a month picker.")
        let start = app.buttons["Start Sync"]

        // December of this year hasn't started (unless it's December, when November stands in).
        let thisMonth = Calendar.current.component(.month, from: .now)
        let future = thisMonth == 12 ? nil : "December"
        if let future {
            month.click(); app.menuItems[future].click()
            XCTAssertTrue(app.staticTexts["That month hasn't started yet."].waitForExistence(timeout: 3))
            XCTAssertFalse(start.isEnabled, "A month still to come can't be imported.")
        }

        // The same month last year can.
        let lastYear = String(Calendar.current.component(.year, from: .now) - 1)
        app.popUpButtons["Year"].click(); app.menuItems[lastYear].click()
        XCTAssertFalse(app.staticTexts["That month hasn't started yet."].exists)
        XCTAssertTrue(start.isEnabled, "A past month can be imported.")
    }

    /// Phase 8: a refused connection names its cause.
    @MainActor
    func testARefusedConnectionSaysTheServerIsntRunning() throws {
        let app = launchConfigured(host: "127.0.0.1")   // this Mac, where nothing listens on 9000: refused at once
        app.buttons["Sync"].click()
        XCTAssertTrue(app.buttons["Start Sync"].waitForExistence(timeout: 5))
        app.buttons["Start Sync"].click()

        // Phase 8: a refused connection is "the server isn't running", not a generic network error.
        let banner = app.staticTexts["SyncBannerMessage"]
        XCTAssertTrue(banner.waitForExistence(timeout: 15), "No sync banner appeared.")
        let refused = NSPredicate(format: "value CONTAINS %@", "server isn't running")
        XCTAssertEqual(XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: refused, object: banner)], timeout: 15),
                       .completed, "The banner should say the server isn't running; it says '\(banner.value ?? "")'.")
    }

    /// Smoke test for the Start Sync path: with a connection set up, start a sync, and keep poking the
    /// window while it runs.
    ///
    /// **This does not reproduce the "No Observable object of type AppModel found" crash** that
    /// prompted the fix in `SyncPanel`. That was seen once against a real, reachable phone; this
    /// test was checked against the pre-fix code and still passed, so treat it as coverage of the
    /// path rather than proof the crash is gone.
    @MainActor
    func testStartingASyncDoesNotCrash() throws {
        let app = launchConfigured(host: "10.255.255.1")   // unroutable: the sync stays "running"
        app.buttons["Sync"].click()

        let startSync = app.buttons["Start Sync"]
        XCTAssertTrue(startSync.waitForExistence(timeout: 5))
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
