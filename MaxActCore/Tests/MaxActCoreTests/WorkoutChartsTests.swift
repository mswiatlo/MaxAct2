import Foundation
import Testing

@testable import MaxActCore

@Suite struct WorkoutChartsTests {
    private let start = Date(timeIntervalSince1970: 1_760_000_000)

    private func point(_ seconds: TimeInterval, _ value: Double) -> ChartPoint {
        ChartPoint(date: start.addingTimeInterval(seconds), value: value)
    }

    /// The closures are non-optional with defaults on purpose: written as
    /// `speedAt?(second) ?? 5`, Swift flattens the optional chain and coalesces a closure's *own*
    /// `nil` return to the default, so there would be no way to express "this fix recorded no
    /// altitude" — which is exactly the case these tests need to cover.
    private func route(
        seconds: Int, gapAfter: Int? = nil, gapSeconds: TimeInterval = 3100,
        speedAt: (Int) -> Double? = { _ in 5 }, altitudeAt: (Int) -> Double? = { _ in 50 }
    ) -> [RoutePoint] {
        var elapsed: TimeInterval = 0
        return (0..<seconds).map { second in
            if let gapAfter, second == gapAfter + 1 { elapsed += gapSeconds }
            defer { elapsed += 1 }
            return RoutePoint(
                coordinate: Coordinate(latitude: 49.25, longitude: -123.1 + Double(second) * 0.00005),
                timestamp: start.addingTimeInterval(elapsed),
                altitudeMeters: altitudeAt(second),
                speedMetersPerSecond: speedAt(second),
                horizontalAccuracyMeters: 8
            )
        }
    }

    @Test("a line is never drawn across a pause")
    func pausesBreakTheSeries() throws {
        // The whole reason segments exist: one series spanning a 51.7-minute stop draws a straight
        // line implying a steady heart rate and altitude right through it.
        let series = WorkoutSeries(workoutID: "W", route: route(seconds: 1000, gapAfter: 400))
        let segments = WorkoutCharts.elevation(series)

        #expect(segments.count == 2)
        let firstEnd = try #require(segments[0].points.last).date
        let secondStart = try #require(segments[1].points.first).date
        #expect(secondStart.timeIntervalSince(firstEnd) > RouteQuality.pauseGapSeconds)
    }

    @Test("an uninterrupted workout is a single segment")
    func noPauseNoSplit() {
        let series = WorkoutSeries(workoutID: "W", route: route(seconds: 600))
        #expect(WorkoutCharts.elevation(series).count == 1)
    }

    @Test("heart rate carries the band it was bucketed into")
    func heartRateIsABand() throws {
        // HAE never sends beat-by-beat data, so a bare line would imply precision it doesn't have.
        let samples = (0..<100).map {
            HeartRateSample(
                date: start.addingTimeInterval(Double($0) * 5),
                minimum: 120, average: 140, maximum: 165
            )
        }
        let segments = WorkoutCharts.heartRate(WorkoutSeries(workoutID: "W", heartRate: samples))
        let first = try #require(segments.first?.points.first)
        let band = try #require(first.band)
        #expect(band.lowerBound == 120)
        #expect(band.upperBound == 165)
        #expect(first.value == 140)
    }

    @Test("a band always contains its own average, even if the source disagrees")
    func bandIsWellFormed() throws {
        // A bucket whose average sits outside its own min/max would trap constructing the range.
        let broken = [HeartRateSample(date: start, minimum: 150, average: 100, maximum: 120)]
        let segments = WorkoutCharts.heartRate(WorkoutSeries(workoutID: "W", heartRate: broken))
        let band = try #require(segments.first?.points.first?.band)
        #expect(band.contains(100))
    }

    @Test("a bucket that spans nothing gets no band, which is every real sample we have")
    func degenerateBucketsHaveNoBand() throws {
        // Measured: across 2,580 samples from five workouts at `metadataAggregation: "seconds"`,
        // min, avg and max were identical every time — a 5-second bucket holds one watch reading.
        // Emitting a band anyway would mean hundreds of zero-height area marks per chart.
        let flat = (0..<50).map {
            HeartRateSample(
                date: start.addingTimeInterval(Double($0) * 5),
                minimum: 142, average: 142, maximum: 142
            )
        }
        let points = WorkoutCharts.heartRate(WorkoutSeries(workoutID: "W", heartRate: flat))
            .flatMap(\.points)
        #expect(points.count == 50)
        #expect(points.allSatisfy { $0.band == nil })
        #expect(points.allSatisfy { $0.value == 142 })
    }

    @Test("the whole chart stays inside the display budget")
    func downsampledToBudget() {
        // 3,311 points was the real worst case; at a few hundred pixels wide most land in the
        // same column.
        let series = WorkoutSeries(workoutID: "W", route: route(seconds: 3311))
        let segments = WorkoutCharts.speed(series, limit: 400)
        let total = segments.reduce(0) { $0 + $1.points.count }
        #expect(total <= 400)
        #expect(total > 100, "but not thinned into uselessness")
    }

    @Test("each segment keeps its real first and last sample")
    func endpointsPreserved() throws {
        let points = (0..<1000).map { point(Double($0), Double($0)) }
        let thinned = WorkoutCharts.thinned(points, to: 50)
        #expect(thinned.count == 50)
        #expect(thinned.first == points.first)
        #expect(thinned.last == points.last)
    }

    @Test("a short fragment either side of a pause survives downsampling")
    func shortSegmentsSurvive() throws {
        // Budgeting purely by share would round a two-point fragment down to nothing.
        var points = (0..<2000).map { point(Double($0), 5) }
        points.append(point(6000, 5))
        points.append(point(6001, 5))
        let segments = WorkoutCharts.segmented(points, limit: 100)

        #expect(segments.count == 2)
        #expect(segments[1].points.count == 2)
        #expect(segments.allSatisfy { $0.points.count >= 2 })
    }

    @Test("speed is smoothed, because raw Doppler swings by whole metres per second")
    func speedIsSmoothed() throws {
        // Alternating 2 and 8 m/s: the real trace does this, and unsmoothed it's unreadable.
        let series = WorkoutSeries(
            workoutID: "W",
            route: route(seconds: 600, speedAt: { $0 % 2 == 0 ? 2 : 8 })
        )
        let values = WorkoutCharts.speed(series, window: 15, limit: 600)
            .flatMap(\.points).map(\.value)
        #expect(values.allSatisfy { $0 > 4 && $0 < 6 }, "should settle near the mean of 5")
    }

    @Test("series with nothing in them produce no segments rather than an empty one")
    func emptyInputs() {
        let empty = WorkoutSeries(workoutID: "W")
        #expect(WorkoutCharts.heartRate(empty).isEmpty)
        #expect(WorkoutCharts.elevation(empty).isEmpty)
        #expect(WorkoutCharts.speed(empty).isEmpty)
        // A route with no altitudes recorded has no elevation profile, but still has speed.
        let noAltitude = WorkoutSeries(
            workoutID: "W", route: route(seconds: 100, altitudeAt: { _ in nil })
        )
        #expect(WorkoutCharts.elevation(noAltitude).isEmpty)
        #expect(!WorkoutCharts.speed(noAltitude).isEmpty)
    }
}
