import Foundation
import Testing
@testable import MaxActCore

/// Issue 31: colouring a route by elevation, heart rate or pace.
@Suite struct RouteColoringTests {
    static let start = Date(timeIntervalSince1970: 1_760_000_000)

    /// One fix a second heading east, `speed(i)` m/s, at `altitude(i)` m. `gaps` adds seconds
    /// before fix i (a pause).
    static func route(count: Int, speed: (Int) -> Double = { _ in 3 }, altitude: (Int) -> Double? = { _ in 10 },
                      gaps: [Int: TimeInterval] = [:]) -> [RoutePoint] {
        var east = 0.0, time = 0.0
        return (0..<count).map { i in
            if i > 0 { east += speed(i); time += 1 + (gaps[i] ?? 0) }
            return RoutePoint(coordinate: RouteMatcherTests.at(east, 0), timestamp: start.addingTimeInterval(time),
                              altitudeMeters: altitude(i), speedMetersPerSecond: nil, courseDegrees: nil,
                              horizontalAccuracyMeters: 5)
        }
    }

    static func heartRate(_ route: [RoutePoint], bpm: (Int) -> Double) -> [HeartRateSample] {
        route.enumerated().map { i, point in
            HeartRateSample(date: point.timestamp, minimum: bpm(i), average: bpm(i), maximum: bpm(i))
        }
    }

    static func steps(_ gradient: RouteGradient) -> [Int] {
        gradient.runs.compactMap { if case .ramp(let step) = $0.shade { step } else { nil } }
    }

    @Test func solidIsNotAGradient() {
        #expect(RouteGradient(.solid, route: Self.route(count: 50), heartRate: [], profile: nil) == nil)
    }

    @Test func aSteadyClimbRunsFromLowestToHighestStep() throws {
        let route = Self.route(count: 600, altitude: { Double($0) / 10 })   // 0 to 60 m
        let gradient = try #require(RouteGradient(.elevation, route: route, heartRate: [], profile: nil))
        let steps = Self.steps(gradient)
        #expect(steps.first == 0)
        #expect(steps.last == RouteGradient.steps - 1)
        #expect(steps == steps.sorted(), "a steady climb only goes up the ramp: \(steps)")
        let range = try #require(gradient.range)
        #expect(range.low < 5 && range.high > 55)
    }

    /// The line is unbroken: every run starts where the last one ended, and together they hold
    /// every fix.
    @Test func runsJoinUpAndCoverEveryFix() throws {
        let route = Self.route(count: 600, altitude: { Double($0) / 10 })
        let gradient = try #require(RouteGradient(.elevation, route: route, heartRate: [], profile: nil))
        for (a, b) in zip(gradient.runs, gradient.runs.dropFirst()) {
            #expect(a.coordinates.last == b.coordinates.first)
        }
        #expect(gradient.runs.reduce(0) { $0 + $1.coordinates.count } == route.count + gradient.runs.count - 1)
    }

    @Test func fasterIsHigherOnTheRamp() throws {
        let route = Self.route(count: 600, speed: { $0 < 300 ? 2 : 5 })
        let gradient = try #require(RouteGradient(.pace, route: route, heartRate: [], profile: nil))
        let steps = Self.steps(gradient)
        #expect(steps.first == 0 && steps.last == RouteGradient.steps - 1, "\(steps)")
    }

    /// Flat ground with ±2 m of sensor noise: mid-ramp, in a few stretches — not the noise
    /// stretched blue to red, nor shattered into hundreds of pieces.
    @Test func noiseOnFlatGroundStaysMidRamp() throws {
        let route = Self.route(count: 1200, altitude: { 10 + Double(($0 * 7919) % 5) - 2 })
        let gradient = try #require(RouteGradient(.elevation, route: route, heartRate: [], profile: nil))
        #expect(gradient.runs.count < 40, "\(gradient.runs.count) runs")
        let steps = Set(Self.steps(gradient))
        #expect(steps.isSubset(of: [4, 5]), "flat ground should sit mid-ramp: \(steps.sorted())")
        let range = try #require(gradient.range)
        #expect(range.high - range.low >= 10, "the ramp spans at least 10 m")
    }

    @Test func aPauseIsGrey() throws {
        let route = Self.route(count: 300, altitude: { Double($0) / 10 }, gaps: [150: 300])
        let gradient = try #require(RouteGradient(.elevation, route: route, heartRate: [], profile: nil))
        let grey = gradient.runs.filter { $0.shade == .missing }
        #expect(grey.count == 1)
        // The grey run spans the gap: from the last fix before it to the first after.
        #expect(grey.first?.coordinates == [route[149].coordinate, route[150].coordinate])
    }

    @Test func heartRateUsesZonesWithAProfileAndTheRampWithout() throws {
        let route = Self.route(count: 600)
        let samples = Self.heartRate(route) { $0 < 300 ? 110 : 180 }
        let profile = try #require(HeartRateProfile(resting: 55, maximum: 190, curve: .male))
        let zoned = try #require(RouteGradient(.heartRate, route: route, heartRate: samples, profile: profile))
        #expect(zoned.range == nil)
        #expect(zoned.runs.first?.shade == .zone(HeartRateZone.of(110, profile: profile)))
        #expect(zoned.runs.last?.shade == .zone(.z5))

        let ramped = try #require(RouteGradient(.heartRate, route: route, heartRate: samples, profile: nil))
        #expect(ramped.range == RouteGradient.Range(low: 110, high: 180))
    }

    // MARK: Gradient (slope)

    /// 3 m/s, so `percent` % of 3 m a second.
    static func climbing(_ percent: (Int) -> Double, count: Int = 600) -> [RoutePoint] {
        var height = 100.0
        var heights: [Double] = []
        for i in 0..<count { if i > 0 { height += 3 * percent(i) / 100 }; heights.append(height) }
        return route(count: count, altitude: { heights[$0] })
    }

    @Test func aSteadyClimbIsOneStepAboveFlat() throws {
        let gradient = try #require(RouteGradient(.gradient, route: Self.climbing { _ in 5 }, heartRate: [], profile: nil))
        let steps = Set(Self.steps(gradient))
        #expect(steps.count == 1, "a steady 5 % is one colour: \(steps.sorted())")
        #expect(steps.allSatisfy { $0 > RouteGradient.steps / 2 }, "uphill is above mid-ramp")
        let range = try #require(gradient.range)
        #expect(range.low == -range.high, "centred on flat")
    }

    @Test func upIsRedAndDownIsBlue() throws {
        let gradient = try #require(RouteGradient(.gradient, route: Self.climbing { $0 < 300 ? 8 : -8 },
                                                  heartRate: [], profile: nil))
        let steps = Self.steps(gradient)
        #expect(steps.first == RouteGradient.steps - 1, "climbing: \(steps)")
        #expect(steps.last == 0, "descending: \(steps)")
    }

    @Test func flatGroundIsMidRampWithAtLeastEightPercentEachWay() throws {
        let gradient = try #require(RouteGradient(.gradient, route: Self.climbing { _ in 0 }, heartRate: [], profile: nil))
        #expect(Set(Self.steps(gradient)).isSubset(of: [4, 5]))
        #expect(try #require(gradient.range).high >= 8)
    }

    /// Standing still with the height reading wandering ±2 m must not show as a steep spike:
    /// the slope comes from the road either side, here flat.
    @Test func heightNoiseWhileStoppedIsNoSpike() throws {
        let route = Self.route(count: 300, speed: { $0 > 100 && $0 < 200 ? 0 : 3 },
                               altitude: { $0 > 100 && $0 < 200 ? 10 + Double(($0 * 7919) % 5) - 2 : 10 })
        let gradient = try #require(RouteGradient(.gradient, route: route, heartRate: [], profile: nil))
        #expect(Set(Self.steps(gradient)).isSubset(of: [4, 5]), "\(Self.steps(gradient))")
    }

    /// A sparse route — a point every 70 m — still has a slope: the window takes the neighbours.
    @Test func aSparseRouteStillHasAGradient() throws {
        let route = Self.route(count: 100, speed: { _ in 70 }, altitude: { Double($0) * 3.5 })   // 5 %
        let grades = RouteGradient.grades(route)
        #expect(grades.allSatisfy { $0 != nil })
        #expect(abs((grades[50] ?? 0) - 5) < 0.5, "\(String(describing: grades[50]))")
    }

    /// No slope where the whole window covers next to no ground.
    @Test func noGroundCoveredIsGrey() throws {
        let route = Self.route(count: 120, speed: { _ in 0.1 }, altitude: { Double($0 % 3) })
        #expect(RouteGradient.grades(route).allSatisfy { $0 == nil })
    }

    @Test func noHeartRateAtAllIsNoGradient() {
        #expect(RouteGradient(.heartRate, route: Self.route(count: 100), heartRate: [], profile: nil) == nil)
    }
}
