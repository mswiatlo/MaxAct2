import Foundation
import Testing

@testable import MaxActCore

@Suite struct RouteLookupTests {
    private let start = Date(timeIntervalSince1970: 1_790_000_000)

    /// A 1 Hz ride north, then a ten-minute pause, then more riding.
    private func ride() -> [RoutePoint] {
        let first = (0..<60).map { point(at: Double($0), north: Double($0)) }
        let second = (0..<60).map { point(at: 660 + Double($0), north: 60 + Double($0)) }
        return first + second
    }

    private func point(at seconds: TimeInterval, north step: Double) -> RoutePoint {
        RoutePoint(coordinate: Coordinate(latitude: 49.25 + step * 0.0001, longitude: -123.1),
                   timestamp: start.addingTimeInterval(seconds), speedMetersPerSecond: 5)
    }

    @Test("a time finds the fix nearest it")
    func timeLookup() {
        let route = ride()
        #expect(RouteLookup.point(at: start.addingTimeInterval(10.4), in: route)?.timestamp
                == start.addingTimeInterval(10))
        #expect(RouteLookup.point(at: start.addingTimeInterval(10.6), in: route)?.timestamp
                == start.addingTimeInterval(11))
        #expect(RouteLookup.point(at: start, in: route)?.timestamp == start)
    }

    @Test("a time inside a pause has no position, rather than the spot the athlete left")
    func pauseHasNoPosition() {
        let route = ride()
        // Three seconds after the last fix before the pause: still there.
        #expect(RouteLookup.point(at: start.addingTimeInterval(62), in: route) != nil)
        // Five minutes into the pause: nowhere.
        #expect(RouteLookup.point(at: start.addingTimeInterval(360), in: route) == nil)
        // Before the start and after the end, likewise.
        #expect(RouteLookup.point(at: start.addingTimeInterval(-60), in: route) == nil)
        #expect(RouteLookup.point(at: start.addingTimeInterval(2_000), in: route) == nil)
        #expect(RouteLookup.point(at: start, in: []) == nil)
    }

    @Test("a place finds the nearest fix, with how far away it is")
    func coordinateLookup() throws {
        let route = ride()
        let near = try #require(RouteLookup.nearest(
            to: Coordinate(latitude: 49.25 + 30.2 * 0.0001, longitude: -123.1), in: route))
        #expect(near.point.timestamp == start.addingTimeInterval(30))
        #expect(near.meters < 5)

        // Always an answer for a non-empty route — the caller judges whether it was close enough.
        let far = try #require(RouteLookup.nearest(to: Coordinate(latitude: 50, longitude: -120), in: route))
        #expect(far.meters > 100_000)
        #expect(RouteLookup.nearest(to: Coordinate(latitude: 49.25, longitude: -123.1), in: []) == nil)
    }

    @Test("a chart's value is read within the segment spanning the time, never across a pause")
    func chartValue() {
        let segments = [
            ChartSegment(id: 0, points: [ChartPoint(date: start, value: 100),
                                         ChartPoint(date: start.addingTimeInterval(30), value: 130),
                                         ChartPoint(date: start.addingTimeInterval(59), value: 120)]),
            ChartSegment(id: 1, points: [ChartPoint(date: start.addingTimeInterval(660), value: 140),
                                         ChartPoint(date: start.addingTimeInterval(719), value: 150)]),
        ]
        // Thinned marks 30 s apart: any time inside the segment still has a value.
        #expect(RouteLookup.value(at: start.addingTimeInterval(20), in: segments) == 130)
        #expect(RouteLookup.value(at: start.addingTimeInterval(700), in: segments) == 150)
        // In the pause between segments, and outside the chart, there is none.
        #expect(RouteLookup.value(at: start.addingTimeInterval(300), in: segments) == nil)
        #expect(RouteLookup.value(at: start.addingTimeInterval(-1), in: segments) == nil)
    }

    @Test("time lookup stays fast on a long route")
    func longRoute() {
        // 12,645 points is the longest real route stored; binary search shouldn't notice.
        let route = (0..<12_645).map { point(at: Double($0), north: Double($0)) }
        let clock = ContinuousClock()
        let elapsed = clock.measure {
            for second in stride(from: 0, to: 12_645, by: 7) {
                _ = RouteLookup.point(at: start.addingTimeInterval(Double(second) + 0.3), in: route)
            }
        }
        // ~12 ms alone; room for a parallel run, still catching a 10× regression (issue 43).
        #expect(elapsed < .milliseconds(500), "took \(elapsed)")
    }
}
