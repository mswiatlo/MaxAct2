import Foundation
import Testing

@testable import MaxActCore

@Suite struct ElevationEstimateTests {
    /// A route climbing 50 m then dropping 80 m, a point a second, with ±0.4 m of jitter.
    private func route(heights: [Double]) -> [RoutePoint] {
        let t0 = Date(timeIntervalSince1970: 0)
        return heights.enumerated().map { index, height in
            RoutePoint(coordinate: Coordinate(latitude: 49, longitude: -123 + Double(index) * 1e-5),
                       timestamp: t0.addingTimeInterval(Double(index)),
                       altitudeMeters: height + (index.isMultiple(of: 2) ? 0.4 : -0.4))
        }
    }
    private var upThenDown: [Double] {
        (0..<300).map { 100 + Double($0) / 6 } + (0..<300).map { 150 - Double($0) * 80 / 300 }
    }

    @Test("descent is the reported ascent plus the net drop")
    func fromAscent() throws {
        let descent = try #require(ElevationEstimate.descent(reportedAscent: 50, route: route(heights: upThenDown)))
        #expect(abs(descent - 80) < 3, "50 up, start 100, end ~70: \(descent)")
    }

    @Test("without a reported ascent, both are summed along the route")
    func summed() throws {
        let r = route(heights: upThenDown)
        let descent = try #require(ElevationEstimate.descent(reportedAscent: nil, route: r))
        let ascent = try #require(ElevationEstimate.ascent(route: r))
        // The 61-point smoothing rounds this synthetic route's sharp peak off (72 and 44); on real
        // routes the same sum measured a median error of −1 m against Health's figures.
        #expect(descent > 68 && descent < 82, "descent \(descent)")
        #expect(ascent > 40 && ascent < 52, "ascent \(ascent)")
    }

    @Test("a loop's descent equals its ascent; a route without heights gives nothing")
    func edges() {
        let loop = route(heights: (0..<300).map { 100 + Double($0) / 6 } + (0..<300).map { 150 - Double($0) / 6 })
        #expect(abs((ElevationEstimate.descent(reportedAscent: 268, route: loop) ?? 0) - 268) < 2)
        let flat = [RoutePoint(coordinate: Coordinate(latitude: 49, longitude: -123), timestamp: .now)]
        #expect(ElevationEstimate.descent(reportedAscent: 10, route: flat) == nil)
        #expect(ElevationEstimate.ascent(route: flat) == nil)
    }
}
