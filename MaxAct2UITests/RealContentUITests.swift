import AppKit
import XCTest

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

    /// Issue 44: searching, then deleting the term, stalled on the user's library ("California").
    /// XCTest waits for the app to go idle after each key, so how long each key takes is how long
    /// the main thread was busy with it. Prints timings; no screenshots.
    @MainActor
    func testSearchAndDeleteStayResponsive() throws {
        let app = launchMaxAct(extraArguments: ["--ui-testing-real-copy"])
        let table = app.outlines["WorkoutTable"]
        guard table.waitForExistence(timeout: 15) else {
            throw XCTSkip("No real-library copy in place; nothing to measure.")
        }
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.click()
        func timed(_ label: String, _ key: () -> Void) -> Double {
            let start = Date()
            key()
            let ms = Date().timeIntervalSince(start) * 1000
            print(String(format: "SEARCH %@: %.0f ms", label, ms))
            return ms
        }
        var worst = 0.0
        for character in "California" { worst = max(worst, timed("type \(character)") { search.typeText(String(character)) }) }
        for remaining in stride(from: 9, through: 0, by: -1) {
            worst = max(worst, timed("delete to \(remaining)") { search.typeKey(.delete, modifierFlags: []) })
        }
        print(String(format: "SEARCH worst: %.0f ms", worst))
    }

    @MainActor
    func testInspectorLayoutWithRealContent() throws {
        // A plausible profile so the inspector's heart-rate zones draw.
        let app = launchMaxAct(defaults: ["restingHeartRate": "55", "maximumHeartRate": "182", "trimpCurve": "male"],
                               extraArguments: ["--ui-testing-real-copy"])
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
            // Issue 15: the zones below the charts, at the inspector's default (narrowest) width.
            let zone = app.descendants(matching: .any).matching(identifier: "ZoneRow").firstMatch
            let inspector = window.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.5))
            for _ in 0..<6 where !(zone.exists && zone.isHittable) { inspector.scroll(byDeltaX: 0, deltaY: -300) }
            if zone.exists { capture("2c-zones") }
        }

        let edge = window.coordinate(withNormalizedOffset: CGVector(dx: 1, dy: 0.5))
            .withOffset(CGVector(dx: -1, dy: 0))
        edge.press(forDuration: 0.3, thenDragTo: edge.withOffset(CGVector(dx: 300, dy: 0)))
        capture("3-inspector-open-300pt-wider")
    }

    /// Issue 23: the Same Route section over the real library — the newest ride (a route done
    /// hundreds of times stresses the chart) and the newest run — for checking by eye.
    @MainActor
    func testSameRouteWithRealContent() throws {
        let app = launchMaxAct(extraArguments: ["--ui-testing-real-copy"])
        let window = app.windows.firstMatch
        let table = app.outlines["WorkoutTable"]
        guard table.waitForExistence(timeout: 15) else {
            throw XCTSkip("No real-library copy in place; nothing to measure.")
        }
        let count = app.staticTexts["RouteHistoryCount"]
        let inspector = window.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.5))
        let search = app.searchFields.firstMatch
        for kind in ["Cycling", "Running"] {
            // Searching by activity puts that kind at the top; few runs repeat a route (the
            // newest that does is 5th), so step down until one shows the section.
            search.click()
            search.typeKey("a", modifierFlags: .command)
            search.typeText(kind)
            table.cells.element(boundBy: 0).click()
            // The first time, every sketch is built from its series. Under XCTest that took
            // 4 min 20 s for 479 (measured), against ~16 s without it, so wait for it to finish.
            let progress = app.descendants(matching: .any)["RouteHistoryProgress"]
            if progress.waitForExistence(timeout: 5) {
                XCTAssertTrue(progress.waitForNonExistence(timeout: 600), "Sketches never finished building.")
            }
            var found = count.waitForExistence(timeout: 10)
            for _ in 0..<8 where !found {
                app.typeKey(.downArrow, modifierFlags: [])
                found = count.waitForExistence(timeout: 3)
            }
            guard found else {
                print("REAL \(kind): no Same Route section")
                continue
            }
            for _ in 0..<12 where !count.isHittable { inspector.scroll(byDeltaX: 0, deltaY: -200) }
            let text = { (id: String) in (app.staticTexts[id].value as? String ?? "") + app.staticTexts[id].label }
            print("REAL \(kind): \(text("RouteHistoryCount")) | \(text("RouteHistoryFastest")) | \(text("RouteHistoryRank"))")
            Thread.sleep(forTimeInterval: 1)
            let attachment = XCTAttachment(screenshot: window.screenshot())
            attachment.name = "23-same-route-\(kind)"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
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

        // Issue 15: give Training Load a profile so it draws over real data. The values only need
        // to be plausible — this checks the layout, not anyone's physiology.
        let scroll = app.scrollViews["StatisticsScroll"]
        let fields = app.textFields.matching(NSPredicate(format: "placeholderValue == 'required'"))
        let resting = fields.element(boundBy: 0), maximum = fields.element(boundBy: 1)
        for _ in 0..<12 where !(maximum.exists && maximum.isHittable) { scroll.scroll(byDeltaX: 0, deltaY: -250) }
        if maximum.isHittable {
            resting.click(); resting.typeText("55\t")
            maximum.click(); maximum.typeText("182\t")
            app.popUpButtons["Effort curve"].click()
            app.menuItems["Male (1.92)"].click()
            Thread.sleep(forTimeInterval: 1)
            let attachment = XCTAttachment(screenshot: window.screenshot())
            attachment.name = "s0-training-load"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
        // Issue 15: the routes map over real data, without and with the explorer squares.
        let squaresToggle = app.checkBoxes["Show squares"]
        for _ in 0..<20 where !(squaresToggle.exists && squaresToggle.isHittable) { scroll.scroll(byDeltaX: 0, deltaY: -400) }
        if squaresToggle.waitForExistence(timeout: 60) {
            Thread.sleep(forTimeInterval: 3)   // map tiles
            let routes = XCTAttachment(screenshot: window.screenshot())
            routes.name = "s0-routes"; routes.lifetime = .keepAlways; add(routes)
            squaresToggle.click()
            Thread.sleep(forTimeInterval: 2)
            let squares = XCTAttachment(screenshot: window.screenshot())
            squares.name = "s0-routes-squares"; squares.lifetime = .keepAlways; add(squares)
            squaresToggle.click()
        }
        // Issue 15: heart-rate zones, just above the routes, once the histograms are read.
        let zones = app.staticTexts["Heart-Rate Zones"]
        if zones.exists {
            window.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.5)).scroll(byDeltaX: 0, deltaY: 300)
            for _ in 0..<6 where !zones.isHittable { scroll.scroll(byDeltaX: 0, deltaY: 150) }
            Thread.sleep(forTimeInterval: 1)
            let attachment = XCTAttachment(screenshot: window.screenshot())
            attachment.name = "s0-zones"; attachment.lifetime = .keepAlways; add(attachment)
        }
        scroll.scroll(byDeltaX: 0, deltaY: 6000)   // back to the top for the tour below

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
