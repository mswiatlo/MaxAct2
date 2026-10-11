import Foundation
import Testing

@testable import MaxActCore

@Suite struct RouteQualityTests {
    /// Builds a fix. Defaults describe a *good* one, so each test states only what it is varying.
    private func point(
        at seconds: TimeInterval,
        latitude: Double = 49.25,
        longitude: Double = -123.1,
        speed: Double? = 4,
        accuracy: Double? = 10
    ) -> RoutePoint {
        RoutePoint(
            coordinate: Coordinate(latitude: latitude, longitude: longitude),
            timestamp: Date(timeIntervalSince1970: 1_760_000_000 + seconds),
            speedMetersPerSecond: speed,
            horizontalAccuracyMeters: accuracy
        )
    }

    @Test("both conditions are required to reject a fix")
    func rejectionNeedsBoth() {
        // The measured signature: no speed *and* poor accuracy.
        #expect(!RouteQuality.isPlausible(point(at: 0, speed: nil, accuracy: 40)))
        // Either one alone is ordinary. Plenty of good fixes carry no speed, and a poor-accuracy
        // fix still carries a usable position.
        #expect(RouteQuality.isPlausible(point(at: 0, speed: nil, accuracy: 10)))
        #expect(RouteQuality.isPlausible(point(at: 0, speed: 4, accuracy: 40)))
        #expect(RouteQuality.isPlausible(point(at: 0)))
    }

    @Test("the threshold sits between the two measured accuracy populations")
    func thresholdBoundary() {
        // Good fixes measured 8–16 m median, bad ones 34–39 m. 30 m is the boundary, and a fix
        // exactly on it is kept — the limit is what's tolerated, not what's rejected.
        #expect(RouteQuality.isPlausible(point(at: 0, speed: nil, accuracy: 30)))
        #expect(!RouteQuality.isPlausible(point(at: 0, speed: nil, accuracy: 30.1)))
    }

    @Test("a missing accuracy is not grounds for rejection")
    func missingAccuracyIsKept() {
        // Nothing to judge on, and discarding position we can't fault would lose real track.
        #expect(RouteQuality.isPlausible(point(at: 0, speed: nil, accuracy: nil)))
    }

    @Test("cleaning removes the teleport and keeps everything else")
    func cleaningRemovesTheTeleport() {
        var route = (0..<10).map { point(at: Double($0), latitude: 49.25 + Double($0) * 0.0001) }
        // The real artifact: 1,826 m away, one second later, no speed, accuracy 45.8 m.
        route.insert(point(at: 4.5, latitude: 49.2664, speed: nil, accuracy: 45.8), at: 5)

        let cleaned = RouteQuality.cleaned(route)
        #expect(cleaned.count == 10)
        #expect(RouteQuality.discardedCount(route) == 1)
        #expect(!cleaned.contains { $0.coordinate.latitude == 49.2664 })
    }

    @Test("a clean route is returned unchanged")
    func cleanRouteUntouched() {
        let route = (0..<50).map { point(at: Double($0)) }
        #expect(RouteQuality.cleaned(route) == route)
        #expect(RouteQuality.discardedCount(route) == 0)
        #expect(RouteQuality.cleaned([]).isEmpty)
    }

    @Test("genuine speed is never mistaken for an artifact")
    func fastIsNotSuspicious() {
        // Neither rule judges speed. A 90 km/h descent, and successive fixes 25 m apart at 1 Hz —
        // which an instantaneous-speed detector would have flagged — stay.
        #expect(RouteQuality.isPlausible(point(at: 0, speed: 25, accuracy: 10)))
        let descent = (0..<10).map {
            point(at: Double($0), latitude: 49.25 + Double($0) * 0.00025, speed: 25)
        }
        #expect(RouteQuality.cleaned(descent) == descent)
    }

    // MARK: - Out-and-back (issue 11)

    /// A ride at 1 Hz heading north, about 11 m per fix, with a good speed on every point.
    private func ride(_ count: Int) -> [RoutePoint] {
        (0..<count).map { point(at: Double($0), latitude: 49.25 + Double($0) * 0.0001) }
    }

    @Test("the issue 11 teleport is dropped although its accuracy passes")
    func excursionWithGoodAccuracy() {
        // The measured shape: no speed, accuracy 27 m — inside the 30 m limit, so the accuracy
        // rule keeps it — and 2,516 m out from neighbours that are 51 m apart.
        var route = ride(10)
        let spike = point(at: 4.5, latitude: 49.25 + 4 * 0.0001 + 0.0226, speed: nil, accuracy: 27)
        #expect(RouteQuality.isPlausible(spike), "the accuracy rule alone keeps it — the bug")
        route.insert(spike, at: 5)

        #expect(RouteQuality.discardedCount(route) == 1)
        #expect(RouteQuality.cleaned(route) == ride(10))
    }

    @Test("a shorter excursion with looser neighbours is dropped too")
    func excursionWhileStopped() {
        // The second real case, from the 16:02 ride the same day: stopped at a light, a speedless
        // fix 161 m out and 190 m back, with its neighbours 45 m apart — a ratio of 0.28, which a
        // quarter-of-the-excursion rule narrowly missed.
        let base = 49.25
        var route = (0..<5).map { point(at: Double($0), latitude: base, speed: 0.2) }
        route.append(point(at: 5, latitude: base + 0.00145, longitude: -123.1, speed: nil, accuracy: 22))
        route.append(point(at: 11, latitude: base + 0.000405, speed: 0))
        route.append(contentsOf: (1...4).map {
            point(at: 11 + Double($0), latitude: base + 0.000405 + Double($0) * 0.00004)
        })
        #expect(RouteQuality.discardedCount(route) == 1)
        #expect(!RouteQuality.cleaned(route).contains { $0.horizontalAccuracyMeters == 22 })
    }

    @Test("a fix that carries a speed is never treated as an excursion")
    func excursionNeedsNoSpeed() {
        // All 10 measured out-and-backs were speedless, and no fix with a speed ever made one.
        var route = ride(10)
        route.insert(point(at: 4.5, latitude: 49.25 + 4 * 0.0001 + 0.0226, speed: 4), at: 5)
        #expect(RouteQuality.discardedCount(route) == 0)
    }

    @Test("a speedless jump that carries on, rather than coming back, is kept")
    func onwardJumpIsKept() {
        // A long gap — a tunnel, a dropout — puts the next fix far away *and keeps going*. The
        // neighbours then disagree with each other too, so it isn't an excursion.
        var route = ride(5)
        route.append(point(at: 30, latitude: 49.25 + 4 * 0.0001 + 0.003, speed: nil, accuracy: 12))
        route.append(contentsOf: (1...5).map {
            point(at: 30 + Double($0), latitude: 49.25 + 4 * 0.0001 + 0.003 + Double($0) * 0.0001)
        })
        #expect(RouteQuality.discardedCount(route) == 0)
    }

    @Test("small speedless wobbles stay, and the ends of a route are never excursions")
    func boundaries() {
        // 50 m out and back is under the 100 m limit: real GPS scatter, not teleportation.
        var wobble = ride(10)
        wobble.insert(point(at: 4.5, latitude: 49.25 + 4 * 0.0001 + 0.00045, speed: nil), at: 5)
        #expect(RouteQuality.discardedCount(wobble) == 0)

        // No second neighbour to come back to, so nothing to judge by.
        var ends = ride(5)
        ends.insert(point(at: -1, latitude: 49.30, speed: nil, accuracy: 12), at: 0)
        ends.append(point(at: 10, latitude: 49.30, speed: nil, accuracy: 12))
        #expect(RouteQuality.discardedCount(ends) == 0)
    }

    @Test("splits stay plausible through an out-and-back")
    func splitsSurviveExcursion() {
        // The visible symptom: the phantom distance swallowed whole kilometres in a second or two
        // ("3,600 km/h"), and shrank every other kilometre's share of the route with it.
        let start = Date(timeIntervalSince1970: 1_760_000_000)
        var route = (0..<700).map {
            RoutePoint(coordinate: Coordinate(latitude: 49.25 + Double($0) * 0.00005, longitude: -123.1),
                       timestamp: start.addingTimeInterval(Double($0)),
                       speedMetersPerSecond: 5.5, horizontalAccuracyMeters: 8)
        }
        route.insert(RoutePoint(coordinate: Coordinate(latitude: 49.25 + 300 * 0.00005 + 0.0226,
                                                      longitude: -123.1),
                                timestamp: start.addingTimeInterval(300.5),
                                speedMetersPerSecond: nil, horizontalAccuracyMeters: 27), at: 301)
        let distance = 699 * 0.00005 * 111_195   // the route's own length, ~3.9 km
        let workout = Workout(id: "R", kind: .cycling, start: start, end: start.addingTimeInterval(699),
                              duration: 699, distanceMeters: distance, hasRoute: true)

        let splits = WorkoutSplits.splits(for: workout, series: WorkoutSeries(workoutID: "R", route: route))
        #expect(splits.count == 4)
        for split in splits where !split.isPartial {
            let kmh = (split.speedMetersPerSecond ?? 0) * 3.6
            #expect((18...22).contains(kmh), "km \(split.index) at \(kmh) km/h")
        }
    }
}

@Suite struct MovingTimeTests {
    private func series(
        _ samples: [(seconds: TimeInterval, speed: Double?)],
        accuracy: Double = 10
    ) -> WorkoutSeries {
        WorkoutSeries(
            workoutID: "W",
            route: samples.map {
                RoutePoint(
                    coordinate: Coordinate(latitude: 49.25, longitude: -123.1),
                    timestamp: Date(timeIntervalSince1970: 1_760_000_000 + $0.seconds),
                    speedMetersPerSecond: $0.speed,
                    horizontalAccuracyMeters: accuracy
                )
            }
        )
    }

    @Test("time below the activity's stopped threshold doesn't count")
    func stoppedTimeExcluded() throws {
        // 10 s walking, 10 s standing, 10 s walking. Each sample's speed covers the second after it.
        let samples = (0..<31).map { i -> (TimeInterval, Double?) in
            (Double(i), (10..<20).contains(i) ? 0.1 : 1.2)
        }
        let moving = try #require(series(samples).movingTime(for: .walking))
        #expect(moving == 20)
    }

    @Test("a walking pause is not a cycling pause")
    func thresholdsDifferByActivity() throws {
        // 0.6 m/s: a walker strolling, a cyclist stopped at a light.
        let slow = series((0..<11).map { (Double($0), 0.6) })
        #expect(try #require(slow.movingTime(for: .walking)) == 10)
        #expect(slow.movingTime(for: .cycling) == nil)
    }

    @Test("a long gap is a pause, not a sampling interval")
    func pausesAreNotCounted() throws {
        // Measured pauses ran 9.6–51.7 minutes; this is the 51.7-minute one.
        let samples: [(TimeInterval, Double?)] = [
            (0, 4), (1, 4), (2, 4), (3103, 4), (3104, 4),
        ]
        let moving = try #require(series(samples).movingTime(for: .cycling))
        #expect(moving == 3, "the 3,100-second pause must not read as moving time")
    }

    @Test("spurious fixes are excluded before the arithmetic")
    func cleaningAppliesFirst() throws {
        // The bad fix carries no speed, so it can't be judged as moving; the point is that it is
        // gone before the intervals are measured, rather than swallowing the second either side.
        var samples: [(TimeInterval, Double?)] = (0..<11).map { (Double($0), 4) }
        samples.insert((5.5, nil), at: 6)
        let raw = series(samples, accuracy: 40)
        #expect(RouteQuality.discardedCount(raw.route) == 1)
        #expect(try #require(raw.movingTime(for: .cycling)) == 10)
    }

    @Test("no route, a single fix, or an activity without movement all yield nil, never zero")
    func degenerateInputs() {
        #expect(WorkoutSeries(workoutID: "W").movingTime(for: .cycling) == nil)
        #expect(series([(0, 4)]).movingTime(for: .cycling) == nil)
        // Strength training has no notion of moving, so a pace would be meaningless either way.
        #expect(series((0..<11).map { (Double($0), 4) }).movingTime(for: .strengthTraining) == nil)
        // Entirely stopped: nil rather than 0, which would render as an absurd pace.
        #expect(series((0..<11).map { (Double($0), 0.0) }).movingTime(for: .cycling) == nil)
    }
}

@Suite struct EffectiveSpeedTests {
    private func workout(
        kind: ActivityKind = .walking,
        duration: TimeInterval,
        distance: Double?,
        averageSpeed: Double?
    ) -> Workout {
        let start = Date(timeIntervalSince1970: 1_760_000_000)
        return Workout(
            id: "W", kind: kind, start: start, end: start.addingTimeInterval(duration),
            duration: duration, distanceMeters: distance,
            averageSpeedMetersPerSecond: averageSpeed
        )
    }

    @Test("distance over duration wins over HAE's biased average")
    func preferDistanceOverDuration() throws {
        // The measured walk, and the bug it exposed. HAE reported avgSpeed 0.847 m/s — the mean of
        // its per-point speeds, stopped samples included — which rendered as 19:40 /km.
        let walk = workout(duration: 3320, distance: 3729, averageSpeed: 0.847_498_613_472_438)
        let speed = try #require(walk.effectiveSpeedMetersPerSecond)
        #expect(abs(speed - 3729.0 / 3320.0) < 1e-9)
        #expect(WorkoutFormatting.pace(metersPerSecond: speed) == "14:50 /km")
    }

    @Test("the measured rides land where a consistent rider should")
    func ridesAreConsistent() {
        // Four rides by the same person. avgSpeed scattered over 3.75–4.87 m/s; distance ÷ duration
        // should cluster tightly, which is the evidence that it's the unbiased figure.
        let rides = [
            workout(kind: .cycling, duration: 1511, distance: 8325, averageSpeed: 4.547),
            workout(kind: .cycling, duration: 2154, distance: 11663, averageSpeed: 4.282),
            workout(kind: .cycling, duration: 509, distance: 2824, averageSpeed: 4.872),
            workout(kind: .cycling, duration: 2117, distance: 11364, averageSpeed: 3.750),
        ]
        let speeds = rides.compactMap(\.effectiveSpeedMetersPerSecond)
        #expect(speeds.count == 4)
        #expect(speeds.allSatisfy { $0 > 5.3 && $0 < 5.6 })
    }

    @Test("HAE's average is the last resort, not the first choice")
    func fallsBackWhenNoDistance() throws {
        // An indoor session with no distance: biased is better than blank.
        let noDistance = workout(duration: 1800, distance: nil, averageSpeed: 3.2)
        #expect(try #require(noDistance.effectiveSpeedMetersPerSecond) == 3.2)
        // Nothing to go on at all.
        #expect(workout(duration: 1800, distance: nil, averageSpeed: nil)
            .effectiveSpeedMetersPerSecond == nil)
        #expect(workout(duration: 0, distance: 5000, averageSpeed: nil)
            .effectiveSpeedMetersPerSecond == nil)
    }

    @Test("moving pace is faster than elapsed pace when the athlete stopped")
    func movingPaceRefinesTheWalk() throws {
        // The walk again: the watch never auto-paused it, so duration is the full 55.3-minute
        // span and 12.3 minutes of standing still are hidden inside it.
        let walk = workout(duration: 3320, distance: 3729, averageSpeed: nil)
        let route = (0..<3320).map { i -> RoutePoint in
            RoutePoint(
                coordinate: Coordinate(latitude: 49.25, longitude: -123.1),
                timestamp: Date(timeIntervalSince1970: 1_760_000_000 + Double(i)),
                // A quarter of it spent stationary.
                speedMetersPerSecond: i % 4 == 0 ? 0.1 : 1.4,
                horizontalAccuracyMeters: 8
            )
        }
        let series = WorkoutSeries(workoutID: "W", route: route)
        let elapsed = try #require(walk.effectiveSpeedMetersPerSecond)
        let moving = try #require(walk.movingSpeedMetersPerSecond(using: series))
        #expect(moving > elapsed)

        // And it is absent rather than wrong when there's no route to measure.
        #expect(walk.movingSpeedMetersPerSecond(using: WorkoutSeries(workoutID: "W")) == nil)
    }
}
