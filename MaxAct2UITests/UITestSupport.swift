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
    ///
    /// `defaults` become `-key value` pairs, placed *before* `--ui-testing`: after it, AppKit pairs
    /// `-ui-testing` with the next token and the stray value is opened as a document — no window.
    @MainActor
    func launchMaxAct(seed: Int? = nil, defaults: KeyValuePairs<String, String> = [:],
                      extraArguments: [String] = []) -> XCUIApplication {
        let app = XCUIApplication(bundleIdentifier: "com.swiatlowski.MaxAct")
        app.launchArguments = ["-ApplePersistenceIgnoreState", "YES"]
            + defaults.flatMap { ["-\($0.key)", $0.value] }
            + ["--ui-testing"] + extraArguments
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
