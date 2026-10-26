import Foundation
import Testing
@testable import MaxActCore

/// Issue 29: which routes a click on the heatmap lands on.
@Suite struct RouteHeatmapClickTests {
    static func at(_ east: Double, _ north: Double) -> Coordinate { RouteMatcherTests.at(east, north) }

    /// Only the corners, so the segments between them are long — as simplified sketches are.
    static func sketch(_ id: String, _ corners: [(Double, Double)]) -> RouteSketch {
        RouteSketch(workoutID: id, coordinates: corners.map { at($0.0, $0.1) }, tiles: [])
    }

    /// 2 km east along y = 0.
    static let east = sketch("east", [(0, 0), (2000, 0)])
    /// 2 km north along x = 1000, crossing `east` at (1000, 0).
    static let north = sketch("north", [(1000, -1000), (1000, 1000)])

    @Test func aClickOnALongStraightFindsItEvenFarFromAnyVertex() {
        // 1 km from both ends of the only segment, 5 m off the line.
        #expect(RouteHeatmap.routes(near: Self.at(500, 5), within: 20, among: [Self.east]) == ["east"])
    }

    @Test func aClickJustOutsideTheToleranceFindsNothing() {
        #expect(RouteHeatmap.routes(near: Self.at(500, 25), within: 20, among: [Self.east]).isEmpty)
        #expect(RouteHeatmap.routes(near: Self.at(2025, 0), within: 20, among: [Self.east]).isEmpty, "past the end")
    }

    @Test func whereRoutesCrossBothAreFoundNearestFirst() {
        // 3 m from `north`, 8 m from `east`.
        let hits = RouteHeatmap.routes(near: Self.at(1003, 8), within: 20, among: [Self.east, Self.north])
        #expect(hits == ["north", "east"])
    }

    @Test func emptyMapFindsNothing() {
        #expect(RouteHeatmap.routes(near: Self.at(500, 500), within: 20, among: [Self.east, Self.north]).isEmpty)
    }

    /// A route of one point can't be drawn as a line but can still be clicked.
    @Test func aSinglePointRouteIsFoundByDistanceToThePoint() {
        let dot = Self.sketch("dot", [(100, 100)])
        #expect(RouteHeatmap.routes(near: Self.at(110, 100), within: 20, among: [dot]) == ["dot"])
    }
}
