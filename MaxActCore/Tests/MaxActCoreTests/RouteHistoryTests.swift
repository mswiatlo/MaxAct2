import Foundation
import Testing
@testable import MaxActCore

@Suite struct RouteMatcherTests {
    /// A point `east` and `north` metres from a fixed origin.
    static func at(_ east: Double, _ north: Double) -> Coordinate {
        let origin = Coordinate(latitude: 49.26, longitude: -123.10)
        return Coordinate(
            latitude: origin.latitude + north / 111_195,
            longitude: origin.longitude + east / (111_195 * cos(origin.latitude * .pi / 180)))
    }

    /// Points every 20 m along the corners given, in metres east and north.
    static func path(_ corners: [(Double, Double)]) -> [Coordinate] {
        var points: [Coordinate] = []
        for (a, b) in zip(corners, corners.dropFirst()) {
            let length = hypot(b.0 - a.0, b.1 - a.1)
            let steps = max(1, Int(length / 20))
            for step in 0..<steps {
                let t = Double(step) / Double(steps)
                points.append(at(a.0 + (b.0 - a.0) * t, a.1 + (b.1 - a.1) * t))
            }
        }
        if let last = corners.last { points.append(at(last.0, last.1)) }
        return points
    }

    static func prepared(_ points: [Coordinate]) throws -> RouteMatcher.Prepared {
        try #require(RouteMatcher.Prepared(points))
    }

    /// 3 km east, then 2 km north.
    static let commute: [(Double, Double)] = [(0, 0), (3000, 0), (3000, 2000)]

    @Test func theSamePathWithGPSNoiseIsTheSameRoute() throws {
        let clean = Self.path(Self.commute)
        // ±15 m wobble, deterministic.
        let noisy = clean.enumerated().map { index, point in
            let wobble = Double((index * 7919) % 31 - 15)
            return Coordinate(latitude: point.latitude + wobble / 111_195, longitude: point.longitude)
        }
        #expect(RouteMatcher.isSameRoute(try Self.prepared(clean), try Self.prepared(noisy)))
    }

    @Test func theSamePathTheOtherWayIsADifferentRoute() throws {
        let there = Self.path(Self.commute)
        #expect(!RouteMatcher.isSameRoute(try Self.prepared(there), try Self.prepared(there.reversed())))
    }

    /// The case the ends can't catch: a loop starts and finishes in the same place either way round.
    @Test func aLoopDoneBackwardsIsADifferentRoute() throws {
        let loop = Self.path([(0, 0), (1000, 0), (1000, 1000), (0, 1000), (0, 0)])
        #expect(!RouteMatcher.isSameRoute(try Self.prepared(loop), try Self.prepared(loop.reversed())))
        #expect(RouteMatcher.isSameRoute(try Self.prepared(loop), try Self.prepared(loop)))
    }

    /// A different block near one end — the measured 80–90% case — still counts; a different
    /// middle third doesn't.
    @Test func aShortDetourIsTheSameRouteAndALongOneIsNot() throws {
        let base = try Self.prepared(Self.path(Self.commute))
        // 300 m of 5 km taken one block over, 100 m south.
        let shortDetour = Self.path([(0, 0), (2500, 0), (2500, -100), (2800, -100), (2800, 0), (3000, 0), (3000, 2000)])
        #expect(RouteMatcher.isSameRoute(base, try Self.prepared(shortDetour)))
        // 1.5 km of it 300 m away.
        let longDetour = Self.path([(0, 0), (1000, 0), (1000, -300), (2500, -300), (2500, 0), (3000, 0), (3000, 2000)])
        #expect(!RouteMatcher.isSameRoute(base, try Self.prepared(longDetour)))
    }

    @Test func endsTooFarApartAreADifferentRoute() throws {
        let base = try Self.prepared(Self.path(Self.commute))
        // Carries on 400 m past the other's finish.
        let longer = try Self.prepared(Self.path(Self.commute + [(3000, 2400)]))
        #expect(!RouteMatcher.isSameRoute(base, longer))
    }

    @Test func overlapIsZeroForParallelRoutesFarApart() {
        let a = Self.path([(0, 0), (2000, 0)])
        let b = Self.path([(0, 500), (2000, 500)])
        #expect(RouteMatcher.overlap(a, on: b) == 0)
        #expect(RouteMatcher.overlap(a, on: a) == 1)
    }
}

@Suite struct RouteHistoryTests {
    static let day: TimeInterval = 86_400
    static let base = Date(timeIntervalSince1970: 1_750_000_000)

    static func workout(_ id: String, day: Int, minutes: Double, kind: ActivityKind = .cycling) -> Workout {
        let start = base.addingTimeInterval(Double(day) * Self.day)
        return Workout(id: id, kind: kind, start: start, end: start.addingTimeInterval(minutes * 60),
                       duration: minutes * 60, distanceMeters: 5000, hasRoute: true)
    }

    static func route(_ corners: [(Double, Double)] = RouteMatcherTests.commute) -> RouteMatcher.Prepared? {
        RouteMatcher.Prepared(RouteMatcherTests.path(corners))
    }

    static let elsewhere: [(Double, Double)] = [(0, 0), (0, 3000), (-2000, 3000)]

    @Test func countsFastestAndRankAcrossTheSameRouteOnly() throws {
        let workouts = [
            Self.workout("a", day: 0, minutes: 20),
            Self.workout("b", day: 1, minutes: 18),
            Self.workout("c", day: 2, minutes: 22),
            Self.workout("d", day: 3, minutes: 15, kind: .running),  // same path, other kind
            Self.workout("e", day: 4, minutes: 10),                  // other path
        ]
        var routes = Dictionary(uniqueKeysWithValues: ["a", "b", "c", "d"].map { ($0, Self.route()) }).compactMapValues { $0 }
        routes["e"] = Self.route(Self.elsewhere)

        let history = try #require(RouteHistory(for: workouts[2], routes: routes, among: workouts))
        #expect(history.count == 3)
        #expect(history.attempts.map(\.workoutID) == ["a", "b", "c"])   // oldest first
        #expect(history.fastest.workoutID == "b")
        #expect(history.rank == 3)
        #expect(try #require(RouteHistory(for: workouts[1], routes: routes, among: workouts)).rank == 1)
    }

    @Test func aRouteDoneOnceHasNoHistory() {
        let workouts = [Self.workout("a", day: 0, minutes: 20), Self.workout("e", day: 1, minutes: 10)]
        let routes = ["a": Self.route(), "e": Self.route(Self.elsewhere)].compactMapValues { $0 }
        #expect(RouteHistory(for: workouts[0], routes: routes, among: workouts) == nil)
    }

    @Test func aWorkoutWithoutARouteHasNoHistory() {
        let workouts = [Self.workout("a", day: 0, minutes: 20), Self.workout("b", day: 1, minutes: 18)]
        #expect(RouteHistory(for: workouts[0], routes: ["b": Self.route()].compactMapValues { $0 }, among: workouts) == nil)
    }

    /// Equal times: the earlier one is the record, and both share the better place.
    @Test func tiesGoToTheEarlierAttemptAndShareARank() throws {
        let workouts = [
            Self.workout("a", day: 0, minutes: 18),
            Self.workout("b", day: 1, minutes: 18),
            Self.workout("c", day: 2, minutes: 25),
        ]
        let routes = Dictionary(uniqueKeysWithValues: workouts.map { ($0.id, Self.route()) }).compactMapValues { $0 }
        let history = try #require(RouteHistory(for: workouts[1], routes: routes, among: workouts))
        #expect(history.fastest.workoutID == "a")
        #expect(history.rank == 1)
        #expect(try #require(RouteHistory(for: workouts[2], routes: routes, among: workouts)).rank == 3)
    }
}
