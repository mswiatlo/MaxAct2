import Foundation
import Testing

@testable import MaxActCore

@Suite struct RouteSimplifierTests {
    /// The real worst case measured in Phase 1: a 3.5-hour hike at 1 Hz.
    private func longRoute(points: Int = 12_645) -> [Coordinate] {
        (0..<points).map { i in
            let t = Double(i) / 200
            return Coordinate(
                latitude: 49.25 + sin(t) * 0.02 + Double(i) * 0.0000001,
                longitude: -123.1 + cos(t) * 0.02
            )
        }
    }

    @Test("a straight line collapses to its endpoints")
    func straightLineCollapses() {
        let line = (0..<100).map { Coordinate(latitude: 49 + Double($0) * 0.001, longitude: -123) }
        #expect(RouteSimplifier.simplify(line).count == 2)
    }

    @Test("corners are kept — the shape must survive")
    func cornersSurvive() {
        // An L: 50 points east, then 50 north. The corner cannot be dropped.
        var path = (0..<50).map { Coordinate(latitude: 49, longitude: -123 + Double($0) * 0.001) }
        path += (0..<50).map { Coordinate(latitude: 49 + Double($0) * 0.001, longitude: -123 + 0.049) }
        let simplified = RouteSimplifier.simplify(path)
        #expect(simplified.count == 3)
        #expect(simplified.first == path.first)
        #expect(simplified.last == path.last)
    }

    @Test("endpoints are always retained")
    func endpointsRetained() {
        let route = longRoute(points: 500)
        let simplified = RouteSimplifier.simplify(route, fittingPixels: 120)
        #expect(simplified.first == route.first)
        #expect(simplified.last == route.last)
    }

    @Test("order is preserved, so the polyline still traces the route")
    func orderPreserved() {
        let route = longRoute(points: 800)
        let simplified = RouteSimplifier.simplify(route, fittingPixels: 60)
        var searchIndex = 0
        for point in simplified {
            guard let found = route[searchIndex...].firstIndex(of: point) else {
                Issue.record("simplified point not found in order")
                return
            }
            searchIndex = found
        }
    }

    @Test("the worst real route reduces by two orders of magnitude, fast enough to do per row")
    func longRouteReduction() {
        let route = longRoute()
        let started = Date()
        let simplified = RouteSimplifier.simplify(route, fittingPixels: 120)
        let elapsed = Date().timeIntervalSince(started)

        print("12,645 points -> \(simplified.count) in \(String(format: "%.1f", elapsed * 1000)) ms")
        #expect(simplified.count <= 400, "the cap must hold")
        #expect(simplified.count > 20, "but the shape must not be flattened away")
        // An order of magnitude above the ~8 ms measured on an idle machine, on purpose. This
        // catches a 10x regression; it is not a benchmark. A tight threshold fails on a loaded
        // machine and teaches you to ignore the test, which is worse than not having it. The
        // printed figure above is the number to actually look at.
        #expect(elapsed < 0.15, "one row's simplification should stay in the low milliseconds")
    }

    @Test("a pathological route is capped so no single row can be expensive")
    func capHolds() {
        // GPS noise: every point far enough from its neighbours that RDP keeps them all.
        let noisy: [Coordinate] = (0..<20_000).map { i in
            let zigzag: Double = Double(i % 2) * 0.01
            let drift: Double = Double(i) * 0.000001
            let sideways: Double = Double((i / 2) % 2) * 0.01
            return Coordinate(latitude: 49.25 + zigzag + drift, longitude: -123.1 + sideways)
        }
        let simplified = RouteSimplifier.simplify(noisy, fittingPixels: 120, cap: 400)
        #expect(simplified.count <= 400)
        #expect(simplified.last == noisy.last, "decimation must still end where the route ends")
    }

    @Test("degenerate inputs are returned untouched rather than crashing")
    func degenerateInputs() {
        #expect(RouteSimplifier.simplify([]).isEmpty)
        let single = [Coordinate(latitude: 49, longitude: -123)]
        #expect(RouteSimplifier.simplify(single) == single)
        // Every point identical: no segment to measure against.
        let repeated = Array(repeating: single[0], count: 50)
        #expect(RouteSimplifier.simplify(repeated).count == 2)
    }

    @Test("bounds cover every point")
    func boundsAreCorrect() throws {
        let route = longRoute(points: 300)
        let bounds = try #require(CoordinateBounds(route))
        #expect(route.allSatisfy { $0.latitude >= bounds.minLatitude && $0.latitude <= bounds.maxLatitude })
        #expect(route.allSatisfy { $0.longitude >= bounds.minLongitude && $0.longitude <= bounds.maxLongitude })
        #expect(CoordinateBounds([]) == nil)
    }

    @Test("the display span adds headroom around the route")
    func displaySpanAddsHeadroom() throws {
        let bounds = try #require(CoordinateBounds([
            Coordinate(latitude: 49.20, longitude: -123.20),
            Coordinate(latitude: 49.30, longitude: -123.00),
        ]))
        let span = bounds.displaySpan(headroom: 1.3, minimumSpan: 0.003)
        #expect(abs(span.latitude - 0.13) < 1e-9)
        #expect(abs(span.longitude - 0.26) < 1e-9)
    }

    @Test("a treadmill-sized route is floored rather than zoomed to maximum")
    func displaySpanHasFloor() throws {
        // A pool or a treadmill: the whole "route" is GPS jitter a few metres across. Without the
        // floor the map opens as a close-up of one building.
        let bounds = try #require(CoordinateBounds([
            Coordinate(latitude: 49.2000, longitude: -123.1000),
            Coordinate(latitude: 49.2001, longitude: -123.1001),
        ]))
        let span = bounds.displaySpan(headroom: 1.3, minimumSpan: 0.003)
        #expect(span.latitude == 0.003)
        #expect(span.longitude == 0.003)
    }

    @Test("each route gets its own span, so one selection can't inherit another's framing")
    func displaySpanVariesByRoute() throws {
        // The regression this guards: the detail map used to keep the first workout's region for
        // every workout selected afterwards.
        let short = try #require(CoordinateBounds([
            Coordinate(latitude: 49.20, longitude: -123.10),
            Coordinate(latitude: 49.21, longitude: -123.09),
        ]))
        let long = try #require(CoordinateBounds([
            Coordinate(latitude: 49.20, longitude: -123.10),
            Coordinate(latitude: 49.60, longitude: -122.60),
        ]))
        #expect(short.displaySpan(headroom: 1.3, minimumSpan: 0.003).latitude
                < long.displaySpan(headroom: 1.3, minimumSpan: 0.003).latitude)
        #expect(short.centre != long.centre)
    }
}

@Suite struct WorkoutFormattingTests {
    @Test("durations read as clock times and cross the hour boundary correctly")
    func durations() {
        #expect(WorkoutFormatting.duration(2117) == "35:17")
        #expect(WorkoutFormatting.duration(3600) == "1:00:00")
        #expect(WorkoutFormatting.duration(12_645) == "3:30:45")
        #expect(WorkoutFormatting.duration(59) == "0:59")
    }

    @Test("distance switches to metres below a kilometre")
    func distances() {
        #expect(WorkoutFormatting.distance(11_363.6) == "11.36 km")
        #expect(WorkoutFormatting.distance(400) == "400 m")
    }

    @Test("pace and speed each read the way their sport is measured")
    func paceAndSpeed() {
        // 3.75 m/s is 13.5 km/h, or 4:27 per km.
        #expect(WorkoutFormatting.speed(metersPerSecond: 3.750324900751945) == "13.5 km/h")
        #expect(WorkoutFormatting.pace(metersPerSecond: 3.750324900751945) == "4:27 /km")
        #expect(WorkoutFormatting.paceOrSpeed(metersPerSecond: 3.75, for: .cycling).contains("km/h"))
        #expect(WorkoutFormatting.paceOrSpeed(metersPerSecond: 3.75, for: .running).contains("/km"))
    }

    @Test("missing data reads as an em dash, never as zero", arguments: [0.0, -1.0])
    func missingRatherThanZero(value: Double) {
        #expect(WorkoutFormatting.distance(nil) == WorkoutFormatting.missing)
        #expect(WorkoutFormatting.distance(value) == WorkoutFormatting.missing)
        #expect(WorkoutFormatting.energy(kilocalories: nil) == WorkoutFormatting.missing)
        #expect(WorkoutFormatting.heartRate(nil) == WorkoutFormatting.missing)
        #expect(WorkoutFormatting.duration(nil) == WorkoutFormatting.missing)
    }

    @Test("a strength session shows no pace rather than a meaningless one")
    func noPaceForNonDistanceSports() {
        #expect(WorkoutFormatting.paceOrSpeed(metersPerSecond: 2, for: .strengthTraining)
                == WorkoutFormatting.missing)
    }

    @Test("standing still does not render as an absurd pace")
    func absurdPaceSuppressed() {
        #expect(WorkoutFormatting.pace(metersPerSecond: 0.05) == WorkoutFormatting.missing)
    }

    // The preference between distance ÷ duration and HAE's own average, and why, is covered in
    // `EffectiveSpeedTests`. This only checks the arithmetic.
    @Test("average speed is distance over duration")
    func derivedSpeed() {
        let workout = Workout(
            id: "x", kind: .running, start: .now, end: .now.addingTimeInterval(3600),
            duration: 3600, distanceMeters: 10_000
        )
        let speed = workout.effectiveSpeedMetersPerSecond ?? 0
        #expect(abs(speed - 10_000.0 / 3600) < 1e-9)
    }

    @Test("aggregates sum a selection and tolerate missing components")
    func aggregates() {
        let base = Date()
        let workouts = [
            Workout(id: "a", kind: .cycling, start: base, end: base, duration: 3600,
                    distanceMeters: 10_000, activeEnergyKilocalories: 250,
                    elevationAscendedMeters: 100),
            Workout(id: "b", kind: .yoga, start: base, end: base, duration: 1800),
        ]
        let total = WorkoutAggregate(workouts)
        #expect(total.count == 2)
        #expect(total.totalDuration == 5400)
        #expect(total.totalDistanceMeters == 10_000)
        #expect(total.totalEnergyKilocalories == 250)
        #expect(total.totalElevationMeters == 100)
    }
}
