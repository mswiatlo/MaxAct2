import Foundation
import Testing

@testable import MaxActCore

@Suite struct PlaceGridTests {
    /// Great-circle metres, so displacement assertions are in the unit the privacy claim is made
    /// in rather than in degrees.
    private func metres(_ a: Coordinate, _ b: Coordinate) -> Double {
        let earthRadius = 6_371_000.0
        let lat1 = a.latitude * .pi / 180
        let lat2 = b.latitude * .pi / 180
        let deltaLat = lat2 - lat1
        let deltaLon = (b.longitude - a.longitude) * .pi / 180
        let h = sin(deltaLat / 2) * sin(deltaLat / 2)
            + cos(lat1) * cos(lat2) * sin(deltaLon / 2) * sin(deltaLon / 2)
        return 2 * earthRadius * asin(min(1, sqrt(h)))
    }

    @Test("snapping never moves a point more than about half a cell")
    func displacementIsBounded() {
        // The privacy claim: whatever is stored is a kilometre-scale cell, not a building. The
        // measured worst case over a sampled grid at 49° N was 704 m.
        var worst = 0.0
        for latitudeStep in 0..<40 {
            for longitudeStep in 0..<40 {
                let point = Coordinate(
                    latitude: 49.2 + Double(latitudeStep) * 0.0007,
                    longitude: -123.25 + Double(longitudeStep) * 0.0009
                )
                worst = max(worst, metres(point, PlaceGrid.snap(point)))
            }
        }
        #expect(worst < 800, "worst displacement was \(worst) m")
        #expect(worst > 100, "a grid that barely moves anything would not be coarsening")
    }

    @Test("a precise start is not recoverable from what gets stored")
    func precisionIsDiscarded() {
        // Two houses on the same block must be indistinguishable afterwards — that is the point.
        let houseA = Coordinate(latitude: 49.24470, longitude: -123.16000)
        let houseB = Coordinate(latitude: 49.24480, longitude: -123.16010)
        #expect(PlaceGrid.snap(houseA) == PlaceGrid.snap(houseB))
        #expect(metres(houseA, PlaceGrid.snap(houseA)) > 50, "the stored point is not the real one")
    }

    @Test("snapping is idempotent, so a cell is its own representative")
    func idempotent() {
        let point = Coordinate(latitude: 49.2447, longitude: -123.16)
        let once = PlaceGrid.snap(point)
        #expect(PlaceGrid.snap(once) == once)
    }

    @Test("two nearby points can't land on grids of different widths")
    func longitudeStepFollowsTheSnappedLatitude() {
        // Longitude spacing depends on latitude. Deriving it from the *input* latitude would mean
        // two points either side of a latitude boundary snapped against different grids, so a
        // trailhead could produce two cache keys.
        let below = Coordinate(latitude: 49.2489, longitude: -123.1600)
        let above = Coordinate(latitude: 49.2491, longitude: -123.1600)
        let snappedBelow = PlaceGrid.snap(below)
        let snappedAbove = PlaceGrid.snap(above)
        #expect(snappedBelow.latitude == snappedAbove.latitude)
        #expect(snappedBelow.longitude == snappedAbove.longitude)
    }

    @Test("repeat rides from one trailhead share a cache key")
    func cacheKeysCollapse() {
        // This is what makes a seven-year corpus cost a request per place rather than per workout.
        let starts = [
            Coordinate(latitude: 49.24470, longitude: -123.16000),
            Coordinate(latitude: 49.24465, longitude: -123.16012),
            Coordinate(latitude: 49.24502, longitude: -123.15981),
        ]
        let keys = Set(starts.map { PlaceGrid.cacheKey(for: PlaceGrid.snap($0)) })
        #expect(keys.count == 1)

        // And a genuinely different place must not collide with it.
        let elsewhere = PlaceGrid.cacheKey(for: PlaceGrid.snap(
            Coordinate(latitude: 49.2800, longitude: -123.1200)
        ))
        #expect(!keys.contains(elsewhere))
    }

    @Test("extreme coordinates stay valid rather than wrapping into nonsense")
    func extremesAreSafe() {
        // Near the poles a degree of longitude shrinks to nothing; without a floor on cos(lat)
        // the step goes to infinity and everything snaps to the prime meridian.
        let arctic = PlaceGrid.snap(Coordinate(latitude: 89.99, longitude: 120))
        #expect(arctic.latitude <= 90)
        #expect(arctic.longitude >= -180 && arctic.longitude <= 180)
        #expect(arctic.longitude != 0, "the Arctic is not on the prime meridian")

        // Rounding at the antimeridian can push a longitude past 180.
        let dateline = PlaceGrid.snap(Coordinate(latitude: 0, longitude: 179.999))
        #expect(dateline.longitude >= -180 && dateline.longitude <= 180)

        let southern = PlaceGrid.snap(Coordinate(latitude: -33.87, longitude: 151.21))
        #expect(southern.latitude < 0, "the southern hemisphere must stay south")
    }

    @Test("the start comes from the cleaned route, not the raw one")
    func startIgnoresSpuriousFixes() throws {
        // A bad first fix measured up to 1,826 m away would otherwise put the workout in the
        // wrong city — and it is the *first* point, so nothing else would mask it.
        let real = Coordinate(latitude: 49.2447, longitude: -123.1600)
        let route = [
            // No speed and poor accuracy: the measured artifact signature.
            RoutePoint(
                coordinate: Coordinate(latitude: 49.2650, longitude: -123.1100),
                timestamp: Date(timeIntervalSince1970: 0),
                speedMetersPerSecond: nil,
                horizontalAccuracyMeters: 45
            ),
            RoutePoint(
                coordinate: real,
                timestamp: Date(timeIntervalSince1970: 1),
                speedMetersPerSecond: 3,
                horizontalAccuracyMeters: 8
            ),
        ]
        let start = try #require(PlaceGrid.start(of: route))
        #expect(start == PlaceGrid.snap(real))
    }

    @Test("no route, or a route of nothing but bad fixes, yields no start")
    func degenerateRoutes() {
        #expect(PlaceGrid.start(of: []) == nil)
        let allBad = (0..<5).map { index in
            RoutePoint(
                coordinate: Coordinate(latitude: 49, longitude: -123),
                timestamp: Date(timeIntervalSince1970: Double(index)),
                speedMetersPerSecond: nil,
                horizontalAccuracyMeters: 50
            )
        }
        #expect(PlaceGrid.start(of: allBad) == nil)
    }
}
