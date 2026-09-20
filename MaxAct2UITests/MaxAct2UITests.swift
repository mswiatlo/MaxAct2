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

    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication(bundleIdentifier: Self.appBundleIdentifier)
    }

    override func tearDown() {
        app?.terminate()
    }

    @MainActor
    func testAppLaunchesAndShowsMainWindow() throws {
        app.launch()
        XCTAssertTrue(
            app.windows.firstMatch.waitForExistence(timeout: 10),
            "The app launched but no window appeared."
        )
    }

    @MainActor
    func testSidebarOffersTheSavedFilters() throws {
        app.launch()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))

        // Each row's accessibility label is "<title>, <n> workouts", and SwiftUI exposes that as
        // the element's *value* rather than its label — hence the predicate rather than a
        // subscript lookup.
        let sidebar = app.outlines["Sidebar"]
        XCTAssertTrue(sidebar.waitForExistence(timeout: 5))

        for title in ["All Workouts", "Not on Strava", "Upload Failed", "With Route", "Indoor"] {
            let row = sidebar.staticTexts.containing(
                NSPredicate(format: "value BEGINSWITH %@", title)
            ).firstMatch
            XCTAssertTrue(row.waitForExistence(timeout: 5), "Sidebar is missing '\(title)'.")
        }
    }

    @MainActor
    func testSyncAndSelectionCommandsExistInTheMenus() throws {
        app.launch()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))

        // Mac convention: every action must be reachable from the menu bar, not just the toolbar.
        let fileMenu = app.menuBars.menuBarItems["File"]
        XCTAssertTrue(fileMenu.waitForExistence(timeout: 5))
        fileMenu.click()
        XCTAssertTrue(
            app.menuItems["Sync from iPhone"].waitForExistence(timeout: 3),
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
        app.launch()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))

        app.typeKey(",", modifierFlags: .command)

        // The foreground/unlocked constraint is the single most confusing thing about this app,
        // so the settings window must state it rather than leaving people guessing.
        let explanation = app.staticTexts.containing(
            NSPredicate(format: "value CONTAINS[c] 'foreground'")
        ).firstMatch
        XCTAssertTrue(
            explanation.waitForExistence(timeout: 5),
            "Settings should explain that Health Auto Export must stay in the foreground."
        )
    }
}
