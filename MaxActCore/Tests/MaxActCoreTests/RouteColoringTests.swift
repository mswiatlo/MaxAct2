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

    @Test func noHeartRateAtAllIsNoGradient() {
        #expect(RouteGradient(.heartRate, route: Self.route(count: 100), heartRate: [], profile: nil) == nil)
    }
}
