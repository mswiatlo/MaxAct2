import Foundation
import Testing

@testable import MaxActCore

@Suite struct RouteHeatmapTests {
    @Test("explorer tiles match the slippy-map formula, computed independently")
    func tileMaths() {
        #expect(ExplorerTile(Coordinate(latitude: 49.2827, longitude: -123.1207)) == ExplorerTile(x: 2588, y: 5606))
        #expect(ExplorerTile(Coordinate(latitude: 51.4779, longitude: 0)) == ExplorerTile(x: 8192, y: 5450))
        #expect(ExplorerTile(Coordinate(latitude: -33.8568, longitude: 151.2153)) == ExplorerTile(x: 15073, y: 9831))
        let corners = ExplorerTile(x: 2588, y: 5606).corners
        #expect(abs(corners.northWest.latitude - 49.296471) < 1e-5)
        #expect(abs(corners.northWest.longitude - -123.134766) < 1e-5)
        #expect(abs(corners.southEast.latitude - 49.282140) < 1e-5)
        #expect(abs(corners.southEast.longitude - -123.112793) < 1e-5)
    }

    private func series(_ id: String, from start: Coordinate, east metres: Double, points: Int = 400) -> WorkoutSeries {
        let t0 = Date(timeIntervalSince1970: 1_790_000_000)
        let step = metres / Double(points - 1) / (111_320 * cos(start.latitude * .pi / 180))
        let route = (0..<points).map { i in
            RoutePoint(coordinate: Coordinate(latitude: start.latitude, longitude: start.longitude + Double(i) * step),
                       timestamp: t0.addingTimeInterval(Double(i)), speedMetersPerSecond: 5)
        }
        return WorkoutSeries(workoutID: id, route: route)
    }

    private let vancouver = Coordinate(latitude: 49.2827, longitude: -123.1207)
    private let montreal = Coordinate(latitude: 45.5019, longitude: -73.5674)

    @Test("a sketch is simplified for drawing but keeps every tile the full route crossed")
    func sketch() throws {
        // A straight 10 km line east: simplifies to two points, yet crosses ~7 tiles.
        let sketch = try #require(RouteSketch(series: series("A", from: vancouver, east: 10_000)))
        #expect(sketch.coordinates.count <= 3)
        #expect(sketch.tiles.count >= 6)
        #expect(RouteSketch(series: WorkoutSeries(workoutID: "indoor")) == nil)
    }

    @Test("places group by start, are named by their most common label, biggest first")
    func regions() throws {
        let sketches = try ["V1", "V2", "V3"].map { try #require(RouteSketch(series: series($0, from: vancouver, east: 3000))) }
            + [try #require(RouteSketch(series: series("M1", from: montreal, east: 3000)))]
        let names = ["V1": "Vancouver BC", "V2": "Vancouver BC", "V3": "Burnaby BC", "M1": "Montréal QC"]
        let regions = RouteHeatmap.regions(sketches, placeNames: names)
        #expect(regions.map(\.name) == ["Vancouver BC", "Montréal QC"])
        #expect(regions.map(\.count) == [3, 1])
        #expect(regions[0].bounds.minLatitude <= vancouver.latitude && vancouver.latitude <= regions[0].bounds.maxLatitude)
        #expect(RouteHeatmap.regions(sketches.suffix(1), placeNames: [:]).first?.name == "Unnamed place")
        #expect(RouteHeatmap.tiles(sketches).count >= 6)
    }

    @Test("nearby cities are separate places; a suburb is the same place")
    func cities() throws {
        let victoria = Coordinate(latitude: 48.4284, longitude: -123.3656)   // ~95 km away
        let burnaby = Coordinate(latitude: 49.2488, longitude: -122.9805)    // ~11 km away
        let sketches = try [("V", vancouver), ("B", burnaby), ("VIC", victoria)].map { id, start in
            try #require(RouteSketch(series: series(id, from: start, east: 2000)))
        }
        let regions = RouteHeatmap.regions(sketches, placeNames: [:])
        #expect(regions.map(\.count) == [2, 1])
        #expect(regions.last?.workoutIDs == ["VIC"])
    }

    @Test("a place is framed on where most routes are, not stretched by one far-off ride")
    func focus() throws {
        // Straight test routes simplify to two points each, so 100 of them make the trip 1% of the
        // points — still more than one trip weighs in the real library (about 0.5%).
        let home = try (0..<100).map { try #require(RouteSketch(series: series("H\($0)", from: vancouver, east: 3000))) }
        // Starting 20 km west, inside the place's radius, and running another 60 km west.
        let tripStart = Coordinate(latitude: 49.2827, longitude: -123.395)
        let trip = try #require(RouteSketch(series: series("TRIP", from: tripStart, east: -60_000)))
        let place = try #require(RouteHeatmap.regions(home + [trip], placeNames: [:]).first)
        #expect(place.count == 101)
        #expect(place.bounds.minLongitude < -124.0, "the full extent includes the trip")
        #expect(place.focus.minLongitude > -123.2, "the framing doesn't")
        #expect(place.focus.maxLongitude < -123.07)
    }

    @Test("sketches are built once and survive a restart; a route-less workout isn't reloaded")
    func cache() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "RouteHeatmapTests-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let seriesStore = try SeriesStore(directory: root.appending(path: "Series"))
        try await seriesStore.save(series("A", from: vancouver, east: 3000))
        try await seriesStore.save(WorkoutSeries(workoutID: "INDOOR"))

        let first = try RouteSketchCache(directory: root)
        let built = await first.sketches(for: ["A", "INDOOR", "NOT-DOWNLOADED"], seriesStore: seriesStore)
        #expect(built.map(\.workoutID) == ["A"])

        // With the series gone, a fresh cache (as after relaunch) still has the sketch.
        try await seriesStore.delete("A")
        let second = try RouteSketchCache(directory: root)
        let calls = Counter()
        let reloaded = await second.sketches(for: ["A", "INDOOR"], seriesStore: seriesStore) { _, _ in await calls.bump() }
        #expect(reloaded.map(\.workoutID) == ["A"])
        #expect(await calls.value == 0, "nothing should have needed building")
    }
}

private actor Counter {
    var value = 0
    func bump() { value += 1 }
}
