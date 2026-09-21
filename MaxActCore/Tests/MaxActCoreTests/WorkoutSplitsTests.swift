import Foundation
import Testing

@testable import MaxActCore

/// A synthetic workout whose route is a straight eastward line at a known speed, so the expected
/// splits can be reasoned about rather than recorded from output.
private func straightLine(
    kind: ActivityKind = .cycling,
    metersPerSecond: Double = 5,
    seconds: Int = 2000,
    altitudeAt: ((Int) -> Double)? = nil,
    speedAt: ((Int) -> Double)? = nil,
    gapAfter: Int? = nil,
    gapSeconds: TimeInterval = 600
) -> (workout: Workout, series: WorkoutSeries) {
    let start = Date(timeIntervalSince1970: 1_760_000_000)
    // At 49° N a degree of longitude is about 73,000 m; deriving the step from that keeps the
    // haversine distance close to `metersPerSecond` per second.
    let metersPerDegree = 111_320.0 * cos(49.25 * .pi / 180)
    var elapsed: TimeInterval = 0
    var route: [RoutePoint] = []
    for second in 0...seconds {
        if let gapAfter, second == gapAfter + 1 { elapsed += gapSeconds }
        route.append(RoutePoint(
            coordinate: Coordinate(
                latitude: 49.25,
                longitude: -123.1 + Double(second) * metersPerSecond / metersPerDegree
            ),
            timestamp: start.addingTimeInterval(elapsed),
            altitudeMeters: altitudeAt?(second) ?? 50,
            speedMetersPerSecond: speedAt?(second) ?? metersPerSecond,
            horizontalAccuracyMeters: 8
        ))
        elapsed += 1
    }
    let distance = Double(seconds) * metersPerSecond
    let workout = Workout(
        id: "W", kind: kind, start: start, end: start.addingTimeInterval(elapsed),
        duration: Double(seconds), distanceMeters: distance
    )
    return (workout, WorkoutSeries(workoutID: "W", route: route))
}

@Suite struct WorkoutSplitsTests {
    @Test("a steady 10 km ride splits into ten kilometres at the right pace")
    func steadySplits() throws {
        // 5 m/s for 2,000 s = 10 km, so every split should be 200 s.
        let (workout, series) = straightLine(metersPerSecond: 5, seconds: 2000)
        let splits = WorkoutSplits.splits(for: workout, series: series)

        #expect(splits.count == 10)
        #expect(splits.allSatisfy { !$0.isPartial })
        for split in splits {
            #expect(abs(split.movingTime - 200) < 6, "split \(split.index) was \(split.movingTime)s")
            let speed = try #require(split.speedMetersPerSecond)
            #expect(abs(speed - 5) < 0.2)
        }
    }

    @Test("distance is scaled so the splits add up to the workout's own total")
    func distanceIsScaledToTheOfficialTotal() throws {
        // The route measures ~10 km but the workout claims 8 km. Summing raw steps overstates
        // distance by 4.5–12.9% on real data, so the official figure wins and the marks move.
        let (base, series) = straightLine(metersPerSecond: 5, seconds: 2000)
        let workout = Workout(
            id: base.id, kind: base.kind, start: base.start, end: base.end,
            duration: base.duration, distanceMeters: 8000
        )
        let splits = WorkoutSplits.splits(for: workout, series: series)

        #expect(splits.count == 8)
        let total = splits.reduce(0) { $0 + $1.distanceMeters }
        #expect(abs(total - 8000) < 60, "splits should account for the stated distance")
    }

    @Test("a pause does not land inside a split's time")
    func pausesExcluded() throws {
        // The failure this replaces: a 51.7-minute stop sat inside one kilometre and rendered as
        // "57.80 min, 1.0 km/h".
        let (workout, series) = straightLine(
            metersPerSecond: 5, seconds: 2000, gapAfter: 500, gapSeconds: 3100
        )
        let splits = WorkoutSplits.splits(for: workout, series: series)

        #expect(splits.count == 10)
        for split in splits {
            #expect(split.movingTime < 260, "split \(split.index) absorbed the pause")
        }
    }

    @Test("standing still is excluded even when it isn't a gap")
    func stoppedSamplesExcluded() throws {
        // A rider at a light is still sampled at 1 Hz, so there is no gap to find — 14 minutes of
        // one measured ride hid this way.
        let (workout, series) = straightLine(
            metersPerSecond: 5, seconds: 2000,
            speedAt: { second in (400..<600).contains(second) ? 0.0 : 5 }
        )
        let splits = WorkoutSplits.splits(for: workout, series: series)
        let stopped = try #require(splits.first { $0.index == 3 })
        #expect(stopped.movingTime < 190, "the stationary samples should not count as moving")
    }

    @Test("split times sum to roughly the workout's moving duration")
    func splitTimesReconcile() throws {
        // The consistency check that caught the two bugs above.
        let (workout, series) = straightLine(metersPerSecond: 5, seconds: 2000, gapAfter: 900)
        let splits = WorkoutSplits.splits(for: workout, series: series)
        let summed = splits.reduce(0) { $0 + $1.movingTime }
        #expect(abs(summed - workout.duration) < workout.duration * 0.05)
    }

    @Test("the trailing remainder is reported at its real length and flagged")
    func partialSplit() throws {
        // 5 m/s for 1,700 s = 8.5 km: eight full splits and a 500 m tail.
        let (workout, series) = straightLine(metersPerSecond: 5, seconds: 1700)
        let splits = WorkoutSplits.splits(for: workout, series: series)

        #expect(splits.count == 9)
        let last = try #require(splits.last)
        #expect(last.isPartial)
        #expect(abs(last.distanceMeters - 500) < 60)
        #expect(splits.dropLast().allSatisfy { !$0.isPartial })
    }

    @Test("average heart rate is attributed to the split it was recorded in")
    func heartRatePerSplit() throws {
        let (workout, base) = straightLine(metersPerSecond: 5, seconds: 2000)
        // 100 bpm for the first half of the ride, 160 for the second.
        let samples = (0..<400).map { step -> HeartRateSample in
            let seconds = Double(step) * 5
            let rate = seconds < 1000 ? 100.0 : 160.0
            return HeartRateSample(
                date: workout.start.addingTimeInterval(seconds),
                minimum: rate - 5, average: rate, maximum: rate + 5
            )
        }
        let series = WorkoutSeries(workoutID: "W", route: base.route, heartRate: samples)
        let splits = WorkoutSplits.splits(for: workout, series: series)

        #expect(try #require(splits[0].averageHeartRate) == 100)
        #expect(try #require(splits[9].averageHeartRate) == 160)
        // The split straddling the change should land between the two.
        let middle = try #require(splits[4].averageHeartRate)
        #expect(middle > 100 && middle < 160)
    }

    @Test("no route, no distance, or a non-distance activity yields no splits")
    func degenerateInputs() {
        let (workout, series) = straightLine()
        #expect(WorkoutSplits.splits(for: workout, series: WorkoutSeries(workoutID: "W")).isEmpty)

        let noDistance = Workout(
            id: "W", kind: .cycling, start: workout.start, end: workout.end,
            duration: workout.duration, distanceMeters: nil
        )
        #expect(WorkoutSplits.splits(for: noDistance, series: series).isEmpty)

        let strength = Workout(
            id: "W", kind: .strengthTraining, start: workout.start, end: workout.end,
            duration: workout.duration, distanceMeters: 5000
        )
        #expect(WorkoutSplits.splits(for: strength, series: series).isEmpty)
    }
}

@Suite struct ElevationSmoothingTests {
    @Test("smoothing collapses the noise that inflated elevation gain 13-fold")
    func smoothingRemovesNoise() throws {
        // Flat ground, ±4 m of barometric wander. Raw rising deltas claimed 590 m of climbing on
        // a real walk that gained 43 m; the smoothed series should claim almost nothing.
        let (_, series) = straightLine(
            seconds: 2000,
            altitudeAt: { second in 50 + (second % 2 == 0 ? 4 : -4) }
        )
        let raw = series.route.map(\.altitudeMeters)
        let smoothed = WorkoutSplits.smoothedAltitudes(series.route)

        func naiveGain(_ values: [Double?]) -> Double {
            var total = 0.0
            var previous: Double?
            for value in values.compactMap({ $0 }) {
                if let previous { total += max(0, value - previous) }
                previous = value
            }
            return total
        }

        // Each stage matters. The naive sum is the nonsense; smoothing alone still leaves ripple,
        // because a moving average of noise is not monotonic; hysteresis is what finishes the job.
        #expect(naiveGain(raw) > 3000)
        #expect(naiveGain(smoothed) > 20, "smoothing alone would not have been enough")
        #expect(WorkoutSplits.elevationGains(smoothed).reduce(0, +) < 5)
    }

    @Test("a real climb survives smoothing")
    func realClimbSurvives() throws {
        // 200 m gained steadily. Smoothing must not flatten terrain, only noise.
        let (_, series) = straightLine(
            seconds: 2000,
            altitudeAt: { second in 50 + Double(second) * 0.1 }
        )
        let smoothed = WorkoutSplits.smoothedAltitudes(series.route).compactMap { $0 }
        #expect(abs((smoothed.last! - smoothed.first!) - 200) < 15)
    }

    @Test("indices line up with the route, and missing altitudes stay missing")
    func alignmentPreserved() {
        let route = (0..<10).map { index in
            RoutePoint(
                coordinate: Coordinate(latitude: 49, longitude: -123),
                timestamp: Date(timeIntervalSince1970: Double(index)),
                altitudeMeters: nil,
                speedMetersPerSecond: 4
            )
        }
        let smoothed = WorkoutSplits.smoothedAltitudes(route)
        #expect(smoothed.count == route.count)
        #expect(smoothed.allSatisfy { $0 == nil }, "nothing nearby to average")
        #expect(WorkoutSplits.movingAverage([], window: 61).isEmpty)
    }
}
