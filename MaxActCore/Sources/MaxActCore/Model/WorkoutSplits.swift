import Foundation

/// One kilometre of a workout.
public struct Split: Identifiable, Hashable, Sendable {
    /// 1-based, as an athlete counts them.
    public let index: Int
    public let distanceMeters: Double
    /// Time spent *moving* within this split — see ``WorkoutSplits``.
    public let movingTime: TimeInterval
    public let elevationGainMeters: Double?
    public let averageHeartRate: Double?

    public var id: Int { index }

    /// True for the trailing remainder, which is shorter than a full split and whose pace is
    /// therefore not comparable to the others without saying so.
    public var isPartial: Bool

    public var speedMetersPerSecond: Double? {
        guard movingTime > 0, distanceMeters > 0 else { return nil }
        return distanceMeters / movingTime
    }

    public init(
        index: Int,
        distanceMeters: Double,
        movingTime: TimeInterval,
        elevationGainMeters: Double? = nil,
        averageHeartRate: Double? = nil,
        isPartial: Bool = false
    ) {
        self.index = index
        self.distanceMeters = distanceMeters
        self.movingTime = movingTime
        self.elevationGainMeters = elevationGainMeters
        self.averageHeartRate = averageHeartRate
        self.isPartial = isPartial
    }
}

/// Per-kilometre splits, computed from the route.
///
/// They have to be computed: the MCP path carries no lap or split data at all. (`.hae` files do
/// carry `intervals.splits`, which is one more argument for the reader noted in Phase 1 — it would
/// let us show HealthKit's own numbers instead of deriving them.)
///
/// Three measured decisions shape this, each of which produced visible nonsense when done the
/// obvious way.
///
/// **Distance is scaled to the workout's own total.** Summing raw steps between 1 Hz fixes
/// overstates distance by 4.5–12.9% even after ``RouteQuality`` filtering, because it accumulates
/// jitter. Scaling the cumulative distance so the route's end equals `workout.distanceMeters`
/// puts the kilometre marks in proportionally correct places and makes the splits add up to the
/// distance shown in the header. The residual bias is that slower sections collect more jitter per
/// metre, so they are very slightly over-weighted.
///
/// **Split time is moving time, not elapsed.** Elapsed time put a 51.7-minute pause inside one
/// kilometre and rendered it as "57.80 min, 1.0 km/h". Excluding long gaps alone wasn't enough
/// either — a rider stopped at lights is still sampled at 1 Hz, so 14 minutes of one ride sat in
/// no gap at all. Using the same rule as ``WorkoutSeries/movingTime(for:)`` makes the splits sum
/// to within a few percent of HAE's `duration` (34.7 against 35.9 min; 8.2 against 8.5; 25.8
/// against 25.2), which is the consistency check worth having.
///
/// **Elevation gain needs smoothing.** Summing rising deltas between raw fixes claimed 590 m of
/// climbing on a 3.7 km city walk whose own `elevationAscended` is 43 m. See
/// ``smoothedAltitudes(_:window:)``.
public enum WorkoutSplits {
    /// Distance covered by a full split. A kilometre, for both foot and wheeled sports — miles are
    /// out of scope, as recorded in PLAN.md §2.
    public static let splitMeters: Double = 1000

    /// `[]` when there is no usable route, no distance to scale against, or the activity has no
    /// notion of moving.
    public static func splits(
        for workout: Workout, series: WorkoutSeries, every splitLength: Double = splitMeters
    ) -> [Split] {
        guard splitLength > 0,
              let totalDistance = workout.distanceMeters, totalDistance > 0,
              let stoppedBelow = workout.kind.stoppedBelowMetersPerSecond
        else { return [] }

        let route = series.cleanedRoute
        guard route.count >= 2 else { return [] }

        let steps = zip(route, route.dropFirst()).map { distance(from: $0.coordinate, to: $1.coordinate) }
        let measured = steps.reduce(0, +)
        guard measured > 0 else { return [] }
        let scale = totalDistance / measured

        let gains = elevationGains(smoothedAltitudes(route))

        var splits: [Split] = []
        var cumulative: Double = 0
        var boundary = splitLength
        var index = 1

        // Per-split accumulators, reset at each boundary.
        var movingTime: TimeInterval = 0
        var gain: Double = 0
        var splitStart = route[0].timestamp

        for (step, position) in zip(steps, steps.indices) {
            let from = route[position]
            let to = route[position + 1]

            let interval = to.timestamp.timeIntervalSince(from.timestamp)
            if interval > 0, interval <= RouteQuality.pauseGapSeconds,
               let speed = from.speedMetersPerSecond, speed >= stoppedBelow {
                movingTime += interval
            }

            gain += gains[position + 1]

            cumulative += step * scale

            if cumulative >= boundary {
                splits.append(Split(
                    index: index,
                    distanceMeters: splitLength,
                    movingTime: movingTime,
                    elevationGainMeters: gain,
                    averageHeartRate: series.averageHeartRate(from: splitStart, to: to.timestamp),
                    isPartial: false
                ))
                index += 1
                boundary += splitLength
                movingTime = 0
                gain = 0
                splitStart = to.timestamp
            }
        }

        // The remainder. Reported with its real length rather than padded, and flagged so its pace
        // isn't read as comparable — a 300 m tail at a traffic light otherwise looks like collapse.
        //
        // Within a metre of a full split it is *not* partial: scaling makes the route end exactly
        // on the stated distance, so a workout whose distance is a round multiple of a kilometre
        // lands a hair under the last boundary and would otherwise report its final full split as
        // a fragment.
        let remainder = cumulative - (boundary - splitLength)
        if remainder >= 50, movingTime > 0 {
            let isFull = remainder >= splitLength - 1
            splits.append(Split(
                index: index,
                distanceMeters: isFull ? splitLength : remainder,
                movingTime: movingTime,
                elevationGainMeters: gain,
                averageHeartRate: series.averageHeartRate(from: splitStart, to: route[route.count - 1].timestamp),
                isPartial: !isFull
            ))
        }
        return splits
    }

    /// Altitudes smoothed with a centred moving average, for elevation gain and for the profile
    /// chart.
    ///
    /// Returns one value per point, `nil` where no altitude was recorded nearby, so indices still
    /// line up with the route.
    public static func smoothedAltitudes(_ route: [RoutePoint], window: Int = 61) -> [Double?] {
        movingAverage(route.map(\.altitudeMeters), window: window)
    }

    /// Height gained, as a per-point increment so callers can total it over any range.
    ///
    /// **Smoothing alone is not enough, and neither is a threshold alone.** Summing every rise
    /// between raw 1 Hz fixes claimed 590 m of climbing on a walk whose own `elevationAscended` is
    /// 43 m. Smoothing over 61 samples got that to 53 m but leaves a ripple, because a moving
    /// average of a noisy signal is still not monotonic. Adding hysteresis — ignore movement until
    /// it exceeds `threshold` from the last accepted height — gives **45 m against HAE's 43**, and
    /// 8 against 10 and 83 against 77 on the other two workouts that report the figure. That is
    /// the only external check available, since HealthKit doesn't document how it derives its own.
    ///
    /// The hysteresis reference deliberately carries across split boundaries: restarting it per
    /// split would discard the part of each climb that hadn't yet cleared the threshold.
    public static func elevationGains(
        _ altitudes: [Double?], threshold: Double = 1
    ) -> [Double] {
        var gains = [Double](repeating: 0, count: altitudes.count)
        var reference: Double?
        for (index, altitude) in altitudes.enumerated() {
            guard let altitude else { continue }
            guard let previous = reference else {
                reference = altitude
                continue
            }
            let change = altitude - previous
            if change > threshold {
                gains[index] = change
                reference = altitude
            } else if change < -threshold {
                reference = altitude
            }
        }
        return gains
    }

    /// Centred moving average that skips missing values, returning one result per input so indices
    /// still line up with the route.
    public static func movingAverage(_ values: [Double?], window: Int) -> [Double?] {
        guard window > 1, !values.isEmpty else { return values }
        let half = window / 2

        // Running sums, so this stays linear rather than O(n·window) — a 12,645-point hike with a
        // 61-sample window would otherwise do over 770,000 additions every time it's drawn.
        var prefix: [Double] = [0]
        var counts: [Int] = [0]
        prefix.reserveCapacity(values.count + 1)
        counts.reserveCapacity(values.count + 1)
        for value in values {
            prefix.append(prefix[prefix.count - 1] + (value ?? 0))
            counts.append(counts[counts.count - 1] + (value == nil ? 0 : 1))
        }

        return values.indices.map { index in
            let lower = max(0, index - half)
            let upper = min(values.count - 1, index + half)
            let count = counts[upper + 1] - counts[lower]
            guard count > 0 else { return nil }
            return (prefix[upper + 1] - prefix[lower]) / Double(count)
        }
    }

    /// Great-circle distance in metres.
    ///
    /// Haversine rather than the flat approximation used for simplification: that one is tuned to
    /// be sub-pixel over a thumbnail, whereas this accumulates over thousands of steps and feeds a
    /// number the user reads.
    public static func distance(from: Coordinate, to: Coordinate) -> Double {
        let earthRadius = 6_371_000.0
        let lat1 = from.latitude * .pi / 180
        let lat2 = to.latitude * .pi / 180
        let deltaLat = lat2 - lat1
        let deltaLon = (to.longitude - from.longitude) * .pi / 180
        let a = sin(deltaLat / 2) * sin(deltaLat / 2)
            + cos(lat1) * cos(lat2) * sin(deltaLon / 2) * sin(deltaLon / 2)
        return 2 * earthRadius * asin(min(1, sqrt(a)))
    }
}

extension WorkoutSeries {
    /// Mean of the bucketed averages whose timestamps fall in `[start, end]`, or `nil` if none do.
    public func averageHeartRate(from start: Date, to end: Date) -> Double? {
        var total = 0.0
        var count = 0
        for sample in heartRate where sample.date >= start && sample.date <= end {
            total += sample.average
            count += 1
        }
        return count > 0 ? total / Double(count) : nil
    }
}
