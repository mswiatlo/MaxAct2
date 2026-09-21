import Foundation

/// One plotted sample. `band` carries a low/high pair where the source data has one.
public struct ChartPoint: Hashable, Sendable {
    public let date: Date
    public let value: Double
    public let band: ClosedRange<Double>?

    public init(date: Date, value: Double, band: ClosedRange<Double>? = nil) {
        self.date = date
        self.value = value
        self.band = band
    }
}

/// A run of samples with no pause inside it.
///
/// Charts are drawn one segment at a time so that **no line is ever drawn across a pause.** A
/// single series spanning a 51.7-minute stop renders as a straight line implying the athlete held
/// a steady heart rate and altitude through it, which is a claim the data doesn't make.
public struct ChartSegment: Identifiable, Hashable, Sendable {
    public let id: Int
    public let points: [ChartPoint]

    public init(id: Int, points: [ChartPoint]) {
        self.id = id
        self.points = points
    }
}

/// Turns a stored series into something drawable.
///
/// This lives in the package rather than the view so the decisions below — smoothing widths, where
/// a line breaks, how much is thrown away — are testable, and so the detail view stays a drawing
/// of data someone else prepared.
public enum WorkoutCharts {
    /// Marks per chart after downsampling.
    ///
    /// A 55-minute walk is 3,311 route points and a long ride 2,509; at a few hundred pixels wide
    /// most of that lands on the same column. 400 keeps every visible feature and keeps three
    /// charts affordable to redraw on every selection change.
    public static let displayLimit = 400

    /// Heart rate: the average, with a min–max band **only where the bucket actually spans a
    /// range**.
    ///
    /// HAE sends `{Min, Avg, Max}` per bucket rather than beat-by-beat samples, which argues for
    /// drawing the range each point flattened. In practice, at the `metadataAggregation:
    /// "seconds"` we request for detail, it never spans anything: across 2,580 samples from five
    /// real workouts, **min, avg and max were identical in every single one**. A 5-second bucket
    /// holds exactly one Apple Watch reading, so there is nothing to flatten.
    ///
    /// The band is kept for the case where it isn't degenerate — a coarser aggregation, or a
    /// future `.hae` import — but emitted only then, so our own data doesn't pay for several
    /// hundred zero-height area marks per chart.
    public static func heartRate(_ series: WorkoutSeries, limit: Int = displayLimit) -> [ChartSegment] {
        let points = series.heartRate.map { sample -> ChartPoint in
            let low = min(sample.minimum, sample.average)
            let high = max(sample.maximum, sample.average)
            return ChartPoint(
                date: sample.date,
                value: sample.average,
                // Sub-bpm ranges are noise, not information.
                band: high - low >= 1 ? low...high : nil
            )
        }
        return segmented(points, limit: limit)
    }

    /// Smoothed altitude against time.
    ///
    /// Smoothed because raw barometric altitude at 1 Hz wanders by metres and the unsmoothed
    /// profile reads as noise rather than terrain — the same reason elevation *gain* needs it.
    public static func elevation(_ series: WorkoutSeries, limit: Int = displayLimit) -> [ChartSegment] {
        let route = series.cleanedRoute
        let altitudes = WorkoutSplits.smoothedAltitudes(route)
        let points = zip(route, altitudes).compactMap { point, altitude -> ChartPoint? in
            guard let altitude else { return nil }
            return ChartPoint(date: point.timestamp, value: altitude)
        }
        return segmented(points, limit: limit)
    }

    /// Smoothed **pace** against time, in seconds per kilometre, for sports read that way.
    ///
    /// A separate series rather than a relabelled speed axis. Plotting speed and formatting the
    /// ticks as pace looked right until a slow walk exposed it: the axis ran from 0 to the fastest
    /// speed, every tick below about 1 m/s converts to a pace beyond 30 min/km — which is not a
    /// number worth printing — and the chart came out with one label and two em dashes.
    ///
    /// Samples slower than the activity's stopped threshold are dropped instead of clamped,
    /// because pace tends to infinity as speed tends to zero and a single stopped sample would
    /// otherwise set the whole scale.
    ///
    /// Callers must plot this on a **reversed** axis: a smaller number is faster, and an athlete
    /// reads up as quicker.
    public static func pace(
        _ series: WorkoutSeries, for kind: ActivityKind, window: Int = 15, limit: Int = displayLimit
    ) -> [ChartSegment] {
        let floor = kind.stoppedBelowMetersPerSecond ?? 0.5
        let route = series.cleanedRoute
        let smoothed = WorkoutSplits.movingAverage(route.map(\.speedMetersPerSecond), window: window)
        let points = zip(route, smoothed).compactMap { point, speed -> ChartPoint? in
            guard let speed, speed >= floor else { return nil }
            return ChartPoint(date: point.timestamp, value: 1000 / speed)
        }
        return segmented(points, limit: limit)
    }

    /// Smoothed speed against time, in metres per second.
    ///
    /// A 15-second window: raw Doppler speed swings by whole metres per second between adjacent
    /// fixes, and the unsmoothed trace is unreadable. Wide enough to show a climb or a descent,
    /// narrow enough to keep a traffic-light stop visible rather than averaging it away.
    public static func speed(
        _ series: WorkoutSeries, window: Int = 15, limit: Int = displayLimit
    ) -> [ChartSegment] {
        let route = series.cleanedRoute
        let smoothed = WorkoutSplits.movingAverage(route.map(\.speedMetersPerSecond), window: window)
        let points = zip(route, smoothed).compactMap { point, speed -> ChartPoint? in
            guard let speed else { return nil }
            return ChartPoint(date: point.timestamp, value: speed)
        }
        return segmented(points, limit: limit)
    }

    /// Splits at pauses, then thins each segment so the whole chart stays within `limit` marks.
    static func segmented(_ points: [ChartPoint], limit: Int) -> [ChartSegment] {
        guard !points.isEmpty else { return [] }

        var runs: [[ChartPoint]] = []
        var current: [ChartPoint] = [points[0]]
        for point in points.dropFirst() {
            let gap = point.date.timeIntervalSince(current[current.count - 1].date)
            if gap > RouteQuality.pauseGapSeconds {
                runs.append(current)
                current = [point]
            } else {
                current.append(point)
            }
        }
        runs.append(current)

        // Budget by share of the total, so a long stretch keeps more detail than a short one and
        // a two-point fragment either side of a pause is never thinned out of existence.
        let total = points.count
        return runs.enumerated().map { index, run in
            let share = max(2, Int((Double(run.count) / Double(total) * Double(limit)).rounded()))
            return ChartSegment(id: index, points: thinned(run, to: share))
        }
    }

    /// Uniform sampling that always keeps the first and last point, so a segment still starts and
    /// ends where it really did.
    static func thinned(_ points: [ChartPoint], to limit: Int) -> [ChartPoint] {
        guard points.count > limit, limit >= 2 else { return points }
        let stride = Double(points.count - 1) / Double(limit - 1)
        var sampled = (0..<(limit - 1)).map { points[Int(Double($0) * stride)] }
        sampled.append(points[points.count - 1])
        return sampled
    }
}
