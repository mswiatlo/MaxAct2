import XCTest

/// Phase 0 launch smoke test. Phase 8 replaces this with a real multi-select / batch-action test.
///
/// The app is launched by bundle identifier rather than via `XCUIApplication()`, because
/// `TEST_TARGET_NAME` — the setting that supplies the implicit target application — is not writable
/// through the available tooling. The scheme's build action builds the app for testing, so the
/// bundle is present by the time this runs.
final class MaxAct2UITests: XCTestCase {
    private static let appBundleIdentifier = "com.swiatlowski.MaxAct"

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testAppLaunchesAndShowsMainWindow() throws {
        let app = XCUIApplication(bundleIdentifier: Self.appBundleIdentifier)
        app.launch()
        addTeardownBlock { app.terminate() }

        XCTAssertTrue(
            app.windows.firstMatch.waitForExistence(timeout: 10),
            "The app launched but no window appeared."
        )
    }
}
