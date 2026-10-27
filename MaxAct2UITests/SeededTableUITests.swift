import AppKit
import XCTest

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
    /// Statistics is drawn right of the sidebar, so everything in it must *report* being right of
    /// the sidebar too. Once its inspector had opened, every element reported a frame one
    /// sidebar-width to the left, and kept doing so after it closed (found 2026-10-27). VoiceOver's
    /// cursor and any click aimed by frame landed off target.
    @MainActor
    func testStatisticsReportWhereTheyAreDrawn() throws {
        let app = launchSeeded()
        let sidebar = app.outlines["Sidebar"]
        XCTAssertTrue(sidebar.waitForExistence(timeout: 15))
        sidebar.staticTexts.containing(NSPredicate(format: "value == 'Statistics' OR label == 'Statistics'"))
            .firstMatch.click()
        let scroll = app.scrollViews["StatisticsScroll"]
        XCTAssertTrue(scroll.waitForExistence(timeout: 10))
        let inspector = app.descendants(matching: .any)["StatisticsInspector"]
        let sidebarEdge = sidebar.frame.maxX

        func check(_ when: String) {
            Thread.sleep(forTimeInterval: 0.5)   // past the inspector's 0.2 s slide
            XCTAssertGreaterThanOrEqual(scroll.frame.minX, sidebarEdge - 1, "The statistics \(when)")
            let text = scroll.staticTexts.firstMatch
            XCTAssertGreaterThanOrEqual(text.frame.minX, sidebarEdge, "\(text.label) \(when)")
        }
        check("before the inspector opens")
        app.typeKey("i", modifierFlags: [.control, .command])
        XCTAssertTrue(inspector.waitForExistence(timeout: 5))
        // Strict: once an OS update reports these right, this fails, and the workaround in the
        // heatmap test and this expectation can go. Three layout changes didn't fix it (2026-10-27):
        // no slide-in animation, vertical-only scrolling, and laying the pair out beside the
        // sidebar explicitly. See PLAN.md.
        XCTExpectFailure("Statistics' accessibility frames are a sidebar-width off once the inspector has opened") {
            check("with the inspector open")
        }
        app.typeKey("i", modifierFlags: [.control, .command])
        XCTAssertTrue(inspector.waitForNonExistence(timeout: 5))
        XCTExpectFailure("Statistics' accessibility frames stay a sidebar-width off after the inspector closes") {
            check("after the inspector closes")
        }
    }

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
            attachment.lifetime = .deleteOnSuccess
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

        // The chart sits low in the inspector, and the window's height is whatever the last run
        // (or the real app) left (issue 30): at 780 pt its centre was 4 pt below the window, so the
        // hover pointed outside the app. Scrolling the inspector doesn't move it under XCTest
        // (measured), so make the window tall enough instead.
        let window = app.windows.firstMatch
        if heartRate.frame.maxY > window.frame.maxY - 8 {
            let bottomEdge = window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 1))
                .withOffset(CGVector(dx: 0, dy: -1))
            let shortfall = heartRate.frame.maxY - window.frame.maxY + 40
            bottomEdge.press(forDuration: 0.3, thenDragTo: bottomEdge.withOffset(CGVector(dx: 0, dy: shortfall)))
            Thread.sleep(forTimeInterval: 0.5)
        }
        XCTAssertLessThan(heartRate.frame.maxY, window.frame.maxY,
                          "The heart-rate chart is below the window, so pointing at it would miss the app.")
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
        let fields = app.textFields.matching(NSPredicate(format: "placeholderValue == 'required'"))
        let resting = fields.element(boundBy: 0), maximum = fields.element(boundBy: 1)
        XCTAssertEqual(resting.value as? String ?? "", "", "An unset rate shows its prompt, not \"0\".")
        for _ in 0..<12 where !(maximum.exists && maximum.isHittable) {
            scroll.scroll(byDeltaX: 0, deltaY: -250)
        }
        resting.click(); resting.typeText("55\t")
        maximum.click(); maximum.typeText("190\t")
        let curve = app.popUpButtons["Effort curve"]
        XCTAssertTrue(curve.waitForExistence(timeout: 5), "The curve picker should be labelled for VoiceOver.")
        curve.click()
        app.menuItems["Male (1.92)"].click()

        // Each reading is one combined element: "Fitness, 12".
        func reading(_ name: String) -> XCUIElement {
            app.staticTexts.containing(NSPredicate(format: "value BEGINSWITH %@", "\(name), ")).firstMatch
        }
        XCTAssertTrue(reading("Fitness").waitForExistence(timeout: 5), "Fitness should appear once set.")
        XCTAssertTrue(reading("Fatigue").exists)
        XCTAssertTrue(reading("Form").exists)
        XCTAssertFalse(prompt.exists, "The prompt goes once the details are set.")
        let attachment = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        attachment.name = "15-training-load"
        attachment.lifetime = .deleteOnSuccess
        add(attachment)
    }

    /// Issue 15: Statistics draws every route on one map and counts the explorer squares.
    @MainActor
    func testRoutesMapShowsExplorerSquares() throws {
        let app = launchSeeded()
        let sidebar = app.outlines["Sidebar"]
        XCTAssertTrue(sidebar.waitForExistence(timeout: 15))
        sidebar.staticTexts.containing(NSPredicate(format: "value == 'Statistics' OR label == 'Statistics'"))
            .firstMatch.click()
        let scroll = app.scrollViews["StatisticsScroll"]
        XCTAssertTrue(scroll.waitForExistence(timeout: 10))

        let toggle = app.checkBoxes["Show squares"]
        for _ in 0..<15 where !(toggle.exists && toggle.isHittable) { scroll.scroll(byDeltaX: 0, deltaY: -400) }
        XCTAssertTrue(toggle.waitForExistence(timeout: 20), "The routes section should finish preparing and offer squares.")
        let count = app.staticTexts.containing(NSPredicate(format: "value BEGINSWITH 'Explorer squares, '")).firstMatch
        XCTAssertTrue(count.exists, "The explorer-square count should be shown.")
        let squares = Int((count.value as? String ?? "").split(separator: " ").last ?? "") ?? 0
        XCTAssertGreaterThan(squares, 0, "Seeded routes cross at least one square.")
        XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH 'Map of '")).firstMatch.exists)
    }

    /// Issue 31: the inspector map's menu colours *that workout's* route by elevation, with a
    /// legend of the low and high values. Another workout stays solid; the first keeps its
    /// choice; back to Solid, the legend goes. The seed's altitudes run 5–35 m.
    @MainActor
    func testTheRouteCanBeColouredByElevation() throws {
        let app = launchSeeded()
        let table = app.outlines["WorkoutTable"]
        XCTAssertTrue(table.waitForExistence(timeout: 15))
        table.cells.element(boundBy: 0).click()

        let menu = app.descendants(matching: .any)["RouteColoringMenu"]
        XCTAssertTrue(menu.waitForExistence(timeout: 15), "The route map should offer colouring.")
        let menuText = { (menu.value as? String ?? "") + menu.label + menu.title }
        XCTAssertTrue(menuText().contains("Solid"), "Solid by default, named as such: \(menuText())")
        let legend = app.descendants(matching: .any)["RouteColoringLegend"]
        XCTAssertFalse(legend.exists, "Solid: no legend.")

        menu.click()
        app.menuItems["Elevation"].click()
        XCTAssertTrue(legend.waitForExistence(timeout: 10), "Colouring by elevation should show a legend.")
        let text = (legend.value as? String ?? "") + legend.label
        XCTAssertTrue(text.contains(" m"), "The legend should give heights: \(text)")

        // Gradient: the slope, in percent either side of flat.
        menu.click()
        app.menuItems["Gradient"].click()
        let percent = NSPredicate(format: "label CONTAINS '%' OR value CONTAINS '%'")
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "RouteColoringLegend")
            .matching(percent).firstMatch.waitForExistence(timeout: 10),
                      "Colouring by gradient should show slopes: \((legend.value as? String ?? "") + legend.label)")
        menu.click()
        app.menuItems["Elevation"].click()

        // Per workout: the next workout with a route is still solid.
        var steps = 0
        repeat {
            app.typeKey(.downArrow, modifierFlags: [])
            steps += 1
            Thread.sleep(forTimeInterval: 0.5)
        } while !menu.exists && steps < 15
        XCTAssertTrue(menu.exists, "Another workout with a route should come up.")
        XCTAssertTrue(menuText().contains("Solid"), "Another workout keeps its own (solid) colouring: \(menuText())")
        XCTAssertFalse(legend.exists)

        // And the first keeps Elevation.
        for _ in 0..<steps { app.typeKey(.upArrow, modifierFlags: []) }
        XCTAssertTrue(legend.waitForExistence(timeout: 10), "The first workout should still be coloured by elevation.")

        menu.click()
        app.menuItems["Solid"].click()
        XCTAssertTrue(legend.waitForNonExistence(timeout: 5), "Back to Solid, the legend should go.")
    }

    /// Issue 29: clicking a route on the heatmap opens its workout; where routes overlap, a picker
    /// lists them. The seed's routes are loops of different sizes around one point, and its two
    /// identical rides share a loop, so a sweep along the centre line meets both cases.
    ///
    /// Aimed by window position, from the map's frame read before anything opens. Once the
    /// inspector has opened in Statistics, every element there reports an accessibility frame
    /// 223 pt left of where it's drawn — the sidebar's width — even after it closes again
    /// (measured 2026-10-27: the map reported at x 129.5 while drawn at ~353, and at 328 rather than
    /// 551 once the inspector had closed). Aimed by the map's own frame, the sweep clicked
    /// off the map after its first hit and failed 4 runs in 7. The inspector is hidden (⌃⌘I) after
    /// each hit, so the drawn layout is the one the frame was read from.
    @MainActor
    func testClickingTheHeatmapOpensAWorkoutOrOffersAChoice() throws {
        let app = launchSeeded()
        let sidebar = app.outlines["Sidebar"]
        XCTAssertTrue(sidebar.waitForExistence(timeout: 15))
        sidebar.staticTexts.containing(NSPredicate(format: "value == 'Statistics' OR label == 'Statistics'"))
            .firstMatch.click()
        let scroll = app.scrollViews["StatisticsScroll"]
        XCTAssertTrue(scroll.waitForExistence(timeout: 10))
        let toggle = app.checkBoxes["Show squares"]
        for _ in 0..<15 where !(toggle.exists && toggle.isHittable) { scroll.scroll(byDeltaX: 0, deltaY: -400) }
        XCTAssertTrue(toggle.waitForExistence(timeout: 20), "The routes section should finish preparing.")
        let map = app.descendants(matching: .any)["RoutesMap"]
        scrollFullyIntoView(map, scrolling: scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.5)),
                            in: app.windows.firstMatch)

        // Clicks go to whatever is in front at those screen points: once another app's window
        // covered MaxAct and the sweep clicked into it. Make sure MaxAct is frontmost first.
        app.activate()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 5), "MaxAct must be frontmost before clicking the map.")
        let back = app.toolbars.buttons["Back"]
        let inspector = app.descendants(matching: .any)["StatisticsInspector"]
        let picker = app.staticTexts.containing(NSPredicate(format: "value ENDSWITH 'routes pass here'")).firstMatch
        let window = app.windows.firstMatch
        let mapFrame = map.frame, windowFrame = window.frame
        let windowOrigin = window.coordinate(withNormalizedOffset: .zero)
        func onMap(_ dx: Double) -> XCUICoordinate {
            windowOrigin.withOffset(CGVector(dx: mapFrame.minX - windowFrame.minX + dx * mapFrame.width,
                                             dy: mapFrame.midY - windowFrame.minY))
        }
        var openedDirectly = false, offeredChoice = false
        for dx in stride(from: 0.5, through: 0.02, by: -0.01) where !offeredChoice {
            onMap(dx).click()
            if picker.waitForExistence(timeout: 0.5) {
                offeredChoice = true
            } else if inspector.waitForExistence(timeout: 0.5) {
                openedDirectly = back.isEnabled
                // Back to the layout the sweep is aimed by (see above). Not Back itself: that
                // restores the empty selection but leaves the inspector open.
                app.typeKey("i", modifierFlags: [.control, .command])
                XCTAssertTrue(inspector.waitForNonExistence(timeout: 5), "⌃⌘I should hide the inspector.")
                Thread.sleep(forTimeInterval: 0.3)   // its 0.2 s slide out
            }
        }
        if !offeredChoice { print("HEATMAP no choice; map reported at \(map.frame), aimed by \(mapFrame)") }
        XCTAssertTrue(openedDirectly, "Clicking a single route should open its workout.")
        XCTAssertTrue(offeredChoice, "Clicking the two rides' shared loop should offer a choice.")
        XCTAssertTrue((picker.value as? String ?? "").hasPrefix("2 "), "The two identical rides: \(picker.value ?? "")")

        // Picking one opens it in the inspector.
        let row = app.descendants(matching: .any)["HeatmapRoutePicker"].buttons.firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.click()
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "value BEGINSWITH 'Cycling'")).firstMatch
            .waitForExistence(timeout: 5), "The picked ride should open in the inspector.")
        XCTAssertFalse(picker.exists, "The picker should close once a route is picked.")
    }

    /// Issue 15: with a heart-rate profile set, Statistics shows time in each zone. The profile is
    /// passed as launch-argument defaults, which sit over the throwaway settings.
    @MainActor
    func testHeartRateZonesShowTimeInEachZone() throws {
        let app = launchMaxAct(seed: 40, defaults: [
            "restingHeartRate": "55", "maximumHeartRate": "190", "trimpCurve": "male",
        ])
        let sidebar = app.outlines["Sidebar"]
        XCTAssertTrue(sidebar.waitForExistence(timeout: 15))
        sidebar.staticTexts.containing(NSPredicate(format: "value == 'Statistics' OR label == 'Statistics'"))
            .firstMatch.click()
        let scroll = app.scrollViews["StatisticsScroll"]
        XCTAssertTrue(scroll.waitForExistence(timeout: 10))

        let rows = app.descendants(matching: .any).matching(identifier: "ZoneRow")
        let top = rows.element(boundBy: 0)
        for _ in 0..<15 where !(top.exists && top.isHittable) { scroll.scroll(byDeltaX: 0, deltaY: -300) }
        XCTAssertTrue(top.waitForExistence(timeout: 10), "The zones section should list its zones.")
        XCTAssertEqual(rows.count, 6, "Five zones and Below Z1.")
        // Resting 55, maximum 190: Zone 5 starts at 55 + 0.9 × 135 = 176.5, rounded up.
        let label = top.label.isEmpty ? (top.value as? String ?? "") : top.label
        XCTAssertTrue(label.contains("Zone 5") && label.contains("177+ bpm"), "Got \(label)")

        let source = app.staticTexts.containing(NSPredicate(format: "value BEGINSWITH 'From '")).firstMatch
        XCTAssertTrue(source.waitForExistence(timeout: 20))
        let measured = Int((source.value as? String ?? "").split(separator: " ").dropFirst().first ?? "") ?? 0
        XCTAssertGreaterThan(measured, 0, "Seeded detail carries heart rate, so some workouts count.")
        // Unhovered, the zones sum the whole span, not the latest period (user's choice). The seed
        // covers several weeks, so the caption names a range.
        let focus = app.staticTexts["ZonesFocus"]
        let caption = (focus.value as? String ?? "") + focus.label
        XCTAssertTrue(caption.contains(" – "), "The caption should cover the whole span: \(caption)")
        let attachment = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        attachment.name = "15-heart-rate-zones"
        attachment.lifetime = .deleteOnSuccess
        add(attachment)
    }

    /// Issue 15: the inspector shows the same zone breakdown for the selected workout.
    @MainActor
    func testInspectorShowsTheWorkoutsHeartRateZones() throws {
        let app = launchMaxAct(seed: 40, defaults: [
            "restingHeartRate": "55", "maximumHeartRate": "190", "trimpCurve": "male",
        ])
        let table = app.outlines["WorkoutTable"]
        XCTAssertTrue(table.waitForExistence(timeout: 15))
        table.cells.element(boundBy: 0).click()

        let heartRate = app.otherElements.matching(NSPredicate(format: "label == 'Heart Rate'")).firstMatch
        XCTAssertTrue(heartRate.waitForExistence(timeout: 15), "No heart-rate chart.")
        let rows = app.descendants(matching: .any).matching(identifier: "ZoneRow")
        let top = rows.element(boundBy: 0)
        // Scroll over a point that's always in the inspector, not over the chart: since the Same
        // Route section (issue 23) the chart can start below the window, with no hit point.
        let inspector = app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.5))
        for _ in 0..<8 where !(top.exists && top.isHittable) { inspector.scroll(byDeltaX: 0, deltaY: -300) }
        XCTAssertTrue(top.waitForExistence(timeout: 5), "The inspector should list the workout's zones.")
        XCTAssertEqual(rows.count, 6, "Five zones and Below Z1.")
        XCTAssertTrue(top.label.contains("Zone 5") && top.label.contains("177+ bpm"), "Got \(top.label)")
        // Some time somewhere: the shares can't all be 0%.
        XCTAssertTrue((0..<6).contains { !rows.element(boundBy: $0).label.hasSuffix(", 0%") },
                      "A seeded workout with heart rate spends time in some zone.")
        let attachment = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        attachment.name = "15-inspector-zones"
        attachment.lifetime = .deleteOnSuccess
        add(attachment)
    }

    /// Issue 22: repaired data is flagged in the inspector. The first seeded workout carries a
    /// Strava-filled route and heart rate from Health's samples.
    @MainActor
    func testInspectorFlagsRepairedData() throws {
        let app = launchSeeded()
        let table = app.outlines["WorkoutTable"]
        XCTAssertTrue(table.waitForExistence(timeout: 15))
        let notes = app.descendants(matching: .any).matching(identifier: "RepairNote")
        table.cells.element(boundBy: 0).click()
        // `cells` counts every column, so step through rows with the arrow key.
        for _ in 0..<8 where !notes.firstMatch.waitForExistence(timeout: 3) {
            app.typeKey(.downArrow, modifierFlags: [])
        }
        XCTAssertTrue(notes.firstMatch.exists, "The repaired workout should be flagged.")
        let texts = (0..<notes.count).map { notes.element(boundBy: $0) }.map { $0.label + ($0.value as? String ?? "") }
        print("NOTES: \(texts)")
        XCTAssertEqual(notes.count, 2, "Route and heart rate: \(texts)")
        let attachment = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        attachment.name = "22-repair-notes"; attachment.lifetime = .deleteOnSuccess; add(attachment)
    }

    /// Issue 23: a workout whose route was done before shows how often, the fastest and its rank.
    /// The seed has exactly one shared route — two identical rides with equal times, the newer
    /// being the newest workout — so the first row has it, and the tie makes this one the fastest.
    @MainActor
    func testInspectorShowsOtherTimesOnTheSameRoute() throws {
        let app = launchSeeded()
        let table = app.outlines["WorkoutTable"]
        XCTAssertTrue(table.waitForExistence(timeout: 15))
        table.cells.element(boundBy: 0).click()

        let count = app.staticTexts["RouteHistoryCount"]
        XCTAssertTrue(count.waitForExistence(timeout: 15), "The newest ride's route was done twice.")
        let text = { (element: XCUIElement) in (element.value as? String ?? "") + element.label }
        XCTAssertTrue(text(count).contains("2 times"), text(count))
        XCTAssertTrue(text(app.staticTexts["RouteHistoryRank"]).contains("Fastest of 2"),
                      text(app.staticTexts["RouteHistoryRank"]))
        // Placed below the last chart, Elevation (user's choice).
        let elevation = app.otherElements.matching(NSPredicate(format: "label == 'Elevation'")).firstMatch
        XCTAssertTrue(elevation.exists, "No elevation chart.")
        XCTAssertGreaterThan(count.frame.minY, elevation.frame.maxY, "Same Route should sit below the Elevation chart.")

        // And it doesn't linger: moving to the next workouts (no shared route) clears it.
        for _ in 0..<12 where count.exists {
            app.typeKey(.downArrow, modifierFlags: [])
            Thread.sleep(forTimeInterval: 0.5)
        }
        XCTAssertFalse(count.exists, "A workout done once shouldn't show a Same Route section.")
    }

    /// Issue 23: pointing at another attempt in the Same Route chart shows its exact time, and
    /// clicking it opens that workout and scrolls the table to it. The seed's other ride on the
    /// route is a month older — about 30 rows down, well off-screen.
    /// Issue 44: a jump that clears the search rebuilds the table (a big insertion), and the jump
    /// must still scroll to its row. Tag the newer ride, search for the tag (one row), then click
    /// the older ride's attempt: the search clears, 1 row becomes 40, and the older ride shows.
    @MainActor
    func testAJumpThatClearsTheSearchStillScrollsToItsRow() throws {
        let app = launchSeeded()
        let table = app.outlines["WorkoutTable"]
        XCTAssertTrue(table.waitForExistence(timeout: 15))
        table.cells.element(boundBy: 0).click()
        table.cells.element(boundBy: 0).rightClick()
        let tagsMenu = app.menuItems["Tags"]
        XCTAssertTrue(tagsMenu.waitForExistence(timeout: 5))
        tagsMenu.hover()
        let newTag = app.menuItems["New Tag…"]
        XCTAssertTrue(newTag.waitForExistence(timeout: 5))
        newTag.click()
        let field = app.dialogs.textFields.firstMatch.exists
            ? app.dialogs.textFields.firstMatch : app.sheets.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.click()
        field.typeText("Solo")
        let add = app.sheets.buttons["Add"].exists ? app.sheets.buttons["Add"] : app.dialogs.buttons["Add"]
        XCTAssertTrue(add.waitForExistence(timeout: 3))
        add.click()

        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.click()
        search.typeText("Solo")
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "value CONTAINS %@", "1 workouts"))
            .firstMatch.waitForExistence(timeout: 10), "Only the tagged ride should match.")
        XCTAssertTrue(app.staticTexts["RouteHistoryCount"].waitForExistence(timeout: 15))

        let chart = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label == 'Time on this route per attempt'")).firstMatch
        let inspector = app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.5))
        scrollFullyIntoView(chart, scrolling: inspector, in: app.windows.firstMatch)
        let opened = app.staticTexts.containing(NSPredicate(format: "value CONTAINS 'September 9, 2025'")).firstMatch
        var found = false
        search: for dy in stride(from: 0.1, through: 0.9, by: 0.1) {
            for dx in stride(from: 0.0, through: 0.4, by: 0.025) {
                chart.coordinate(withNormalizedOffset: CGVector(dx: dx, dy: dy)).click()
                if opened.waitForExistence(timeout: 0.3) { found = true; break search }
            }
        }
        XCTAssertTrue(found, "Clicking along the chart never opened the other attempt.")
        XCTAssertEqual(search.value as? String ?? "", "", "The jump should clear the search that hid its row.")
        let olderRow = table.staticTexts.matching(NSPredicate(format: "value == 'Sep 9, 2025'")).firstMatch
        XCTAssertTrue(olderRow.waitForExistence(timeout: 5) && olderRow.isHittable,
                      "The rebuilt table should scroll to the ride the jump opened.")
    }

    @MainActor
    func testClickingAnAttemptOpensThatWorkout() throws {
        let app = launchSeeded()
        let table = app.outlines["WorkoutTable"]
        XCTAssertTrue(table.waitForExistence(timeout: 15))
        table.cells.element(boundBy: 0).click()
        XCTAssertTrue(app.staticTexts["RouteHistoryCount"].waitForExistence(timeout: 15))
        // Matched on value: a table cell's text is its value, with an empty label.
        let olderRow = table.staticTexts.matching(NSPredicate(format: "value == 'Sep 9, 2025'")).firstMatch
        XCTAssertFalse(olderRow.exists && olderRow.isHittable, "The older ride should start off-screen.")
        // Where the Date column starts, to check the jump scrolls only vertically: the table is
        // wider than its view with the inspector open, and a centring scroll shifted it sideways.
        let dateColumnX = try XCTUnwrap(laidOutX(of: "Oct 9, 2025", in: table))

        // The chart is one accessibility element that hides its children — the tooltip drawn in it
        // never reaches XCTest (measured) — so find the older attempt's point by clicking: it's
        // the leftmost, at whatever height an all-equal axis puts it. Empty chart ignores clicks.
        let chart = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label == 'Time on this route per attempt'")).firstMatch
        let inspector = app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.5))
        scrollFullyIntoView(chart, scrolling: inspector, in: app.windows.firstMatch)
        let opened = app.staticTexts.containing(NSPredicate(format: "value CONTAINS 'September 9, 2025'")).firstMatch
        var spot: CGVector?
        search: for dy in stride(from: 0.1, through: 0.9, by: 0.1) {
            for dx in stride(from: 0.0, through: 0.4, by: 0.025) {
                chart.coordinate(withNormalizedOffset: CGVector(dx: dx, dy: dy)).click()
                if opened.waitForExistence(timeout: 0.3) { spot = CGVector(dx: dx, dy: dy); break search }
            }
        }
        let found = try XCTUnwrap(spot, "Clicking along the chart never opened the other attempt.")
        let scrolledTo = olderRow.waitForExistence(timeout: 5) && olderRow.isHittable
        if !scrolledTo, app.state == .runningForeground {   // evidence of MaxAct only, never another app in front
            let all = table.staticTexts.matching(NSPredicate(format: "value == 'Sep 9, 2025'")).allElementsBoundByIndex.map { $0.frame }
            print("NOT-SCROLLED all \(all) table \(table.frame) window \(app.windows.firstMatch.frame) sidebar \(app.outlines["Sidebar"].frame)")
            let evidence = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
            evidence.name = "not-scrolled"; evidence.lifetime = .deleteOnSuccess; add(evidence)
        }
        XCTAssertTrue(scrolledTo, "The table should scroll to the clicked ride.")
        Thread.sleep(forTimeInterval: 0.5)   // let the table settle
        // Polled, not read once: in one full run (2026-10-27) the row had scrolled into view but
        // had no laid-out copy yet half a second later.
        var laidOut: CGFloat?
        for _ in 0..<25 where laidOut == nil {
            laidOut = laidOutX(of: "Sep 9, 2025", in: table)
            if laidOut == nil { Thread.sleep(forTimeInterval: 0.2) }
        }
        let afterX = try XCTUnwrap(laidOut, "The clicked ride never laid out in the table.")
        // Once in four full runs this read x 466 against 1516, and it hasn't recurred. Keep the
        // evidence if it does: every copy's frame, the table and window, and the window itself.
        if abs(afterX - dateColumnX) > 1, app.state == .runningForeground {
            let all = table.staticTexts.matching(NSPredicate(format: "value == 'Sep 9, 2025'")).allElementsBoundByIndex.map { $0.frame }
            print("SIDEWAYS before \(dateColumnX) after \(afterX) all \(all) table \(table.frame) window \(app.windows.firstMatch.frame) sidebar \(app.outlines["Sidebar"].frame)")
            let evidence = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
            evidence.name = "sideways-jump"; evidence.lifetime = .deleteOnSuccess; add(evidence)
        }
        XCTAssertEqual(afterX, dateColumnX, accuracy: 1, "The jump scrolled the table sideways.")

        // Issue 32: ⌘[ goes back to the ride the jump started from, ⌘] forward again, and the
        // toolbar's Back does the same as the menu.
        let newer = app.staticTexts.containing(NSPredicate(format: "value CONTAINS 'October 9, 2025'")).firstMatch
        app.typeKey("[", modifierFlags: .command)
        XCTAssertTrue(newer.waitForExistence(timeout: 5), "⌘[ should go back to the ride the jump started from.")
        app.typeKey("]", modifierFlags: .command)
        XCTAssertTrue(opened.waitForExistence(timeout: 5), "⌘] should go forward to the clicked ride again.")
        let backButton = app.toolbars.buttons["Back"]
        XCTAssertTrue(backButton.exists && backButton.isEnabled, "The toolbar should offer Back after a jump.")
        backButton.click()
        XCTAssertTrue(newer.waitForExistence(timeout: 5), "The toolbar's Back should go back too.")
        XCTAssertFalse(backButton.isEnabled, "Nothing further back: Back should be greyed out.")

        // For checking by eye: back on the newest ride, the tooltip over the same point.
        table.cells.element(boundBy: 0).click()
        XCTAssertTrue(app.staticTexts["RouteHistoryCount"].waitForExistence(timeout: 10))
        scrollFullyIntoView(chart, scrolling: inspector, in: app.windows.firstMatch)
        chart.coordinate(withNormalizedOffset: found).hover()
        Thread.sleep(forTimeInterval: 1)
        let attachment = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        attachment.name = "23-same-route-tooltip"
        attachment.lifetime = .deleteOnSuccess
        add(attachment)
    }

    /// Scrolls until `element` is wholly inside the window. `isHittable` isn't enough: it was true
    /// for a chart with only its top 16 of 120 pt on screen (measured), and clicks below that
    /// missed the app.
    @MainActor
    private func scrollFullyIntoView(_ element: XCUIElement, scrolling area: XCUICoordinate, in window: XCUIElement) {
        for _ in 0..<15 where !(element.exists && element.frame.maxY <= window.frame.maxY - 4) {
            area.scroll(byDeltaX: 0, deltaY: -150)
        }
        XCTAssertLessThanOrEqual(element.frame.maxY, window.frame.maxY, "\(element) is still below the window.")
    }

    /// Where a date cell starts, reading only a copy that's laid out. The table recycles cells,
    /// and `firstMatch` alternated between the visible cell (x 1516) and a recycled one with an
    /// empty frame (x 0) across two reads a moment apart (measured).
    /// Retried briefly: once, every copy read as empty a moment after the row was hittable.
    @MainActor
    private func laidOutX(of date: String, in table: XCUIElement) -> CGFloat? {
        for _ in 0..<10 {
            if let x = table.staticTexts.matching(NSPredicate(format: "value == %@", date)).allElementsBoundByIndex
                .map({ $0.frame }).first(where: { $0.width > 0 })?.minX { return x }
            Thread.sleep(forTimeInterval: 0.2)
        }
        return nil
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
