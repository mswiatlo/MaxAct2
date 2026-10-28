import AppKit
import XCTest

/// The README's screenshots (issue 36), from the showcase library (`--ui-testing-showcase`):
/// realistic workouts on real Vancouver paths, never the user's library. Window-only, through
/// `XCUIElement.screenshot()`.
///
/// Not a test. Skipped unless `/tmp/maxact-readme-screenshots` exists, so it costs nothing in a
/// normal run. To refresh the images: turn on Do Not Disturb (a banner over the window lands in
/// the shot), `touch` that file, run this class, export the attachments
/// (`xcrun xcresulttool export attachments`), copy them to `docs/`, then delete the marker and
/// the result bundle.
final class ReadmeScreenshots: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
        guard FileManager.default.fileExists(atPath: "/tmp/maxact-readme-screenshots") else {
            throw XCTSkip("README screenshots are taken on request only.")
        }
    }

    /// The showcase, with its heart-rate profile so Statistics shows training load and zones.
    @MainActor
    private func launch() -> XCUIApplication {
        launchMaxAct(defaults: ["restingHeartRate": "54", "maximumHeartRate": "188", "trimpCurve": "male"],
                     extraArguments: ["--ui-testing-showcase"])
    }

    @MainActor
    private func keep(_ app: XCUIApplication, _ name: String) {
        Thread.sleep(forTimeInterval: 2)   // map tiles and thumbnails settle
        let attachment = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// Steps down the table until the inspector shows `activity` covering `distance` ("10.7").
    /// Which row that is depends on the weekday: the library is dated back from today.
    @MainActor
    private func select(_ app: XCUIApplication, _ activity: String, distance: String) {
        let table = app.outlines["WorkoutTable"]
        XCTAssertTrue(table.waitForExistence(timeout: 15))
        table.cells.element(boundBy: 0).click()
        // Only the inspector counts: the sidebar lists activities and the table distances too.
        func inInspector(_ query: XCUIElementQuery) -> Bool {
            query.allElementsBoundByIndex.contains { $0.frame.minX > table.frame.maxX - 1 }
        }
        let distances = app.staticTexts.matching(NSPredicate(format: "value BEGINSWITH %@ AND value ENDSWITH ' km'", distance))
        let titles = app.staticTexts.matching(NSPredicate(format: "value == %@ OR label == %@", activity, activity))
        for _ in 0..<30 {
            if inInspector(titles) && inInspector(distances) { return }
            app.typeKey(.downArrow, modifierFlags: [])
            Thread.sleep(forTimeInterval: 0.4)
        }
        XCTFail("No \(activity) of \(distance) km found")
    }

    @MainActor
    private func openStatistics(_ app: XCUIApplication) -> XCUIElement {
        let sidebar = app.outlines["Sidebar"]
        XCTAssertTrue(sidebar.waitForExistence(timeout: 15))
        sidebar.staticTexts.containing(NSPredicate(format: "value == 'Statistics' OR label == 'Statistics'"))
            .firstMatch.click()
        let scroll = app.scrollViews["StatisticsScroll"]
        XCTAssertTrue(scroll.waitForExistence(timeout: 10))
        return scroll
    }

    /// The seawall run in the inspector, then its Same Route history.
    @MainActor
    func testWorkoutsAndInspector() throws {
        let app = launch()
        XCTAssertTrue(app.images["Route map"].firstMatch.waitForExistence(timeout: 45))
        select(app, "Running", distance: "10.7")
        XCTAssertTrue(app.descendants(matching: .any)["RouteColoringMenu"].waitForExistence(timeout: 15))
        keep(app, "1-workouts")

        let count = app.staticTexts["RouteHistoryCount"]
        let inspector = app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.5))
        for _ in 0..<12 where !(count.exists && count.isHittable) { inspector.scroll(byDeltaX: 0, deltaY: -300) }
        XCTAssertTrue(count.exists, "The seawall run is done every other week.")
        keep(app, "3-same-route")
    }

    /// The Grouse Grind, its route coloured by elevation.
    @MainActor
    func testElevation() throws {
        let app = launch()
        select(app, "Hiking", distance: "1.9")
        let menu = app.descendants(matching: .any)["RouteColoringMenu"]
        XCTAssertTrue(menu.waitForExistence(timeout: 15))
        menu.click()
        app.menuItems["Elevation"].click()
        XCTAssertTrue(app.descendants(matching: .any)["RouteColoringLegend"].waitForExistence(timeout: 10))
        keep(app, "2-elevation")
    }

    /// Statistics from the top; then training load and zones; then the routes map.
    @MainActor
    func testStatistics() throws {
        let app = launch()
        let scroll = openStatistics(app)
        keep(app, "4-statistics")

        let load = app.staticTexts.containing(NSPredicate(format: "value BEGINSWITH 'Fitness, '")).firstMatch
        for _ in 0..<15 where !(load.exists && load.isHittable) { scroll.scroll(byDeltaX: 0, deltaY: -300) }
        XCTAssertTrue(load.exists)
        scroll.scroll(byDeltaX: 0, deltaY: -150)
        keep(app, "5-training-load")

        let toggle = app.checkBoxes["Show squares"]
        for _ in 0..<15 where !(toggle.exists && toggle.isHittable) { scroll.scroll(byDeltaX: 0, deltaY: -400) }
        XCTAssertTrue(toggle.waitForExistence(timeout: 30))
        let map = app.descendants(matching: .any)["RoutesMap"]
        scrollFullyIntoView(map, scrolling: scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.5)),
                            in: app.windows.firstMatch)
        keep(app, "6-routes-map")
    }
}
