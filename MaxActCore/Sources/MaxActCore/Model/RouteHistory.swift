import Foundation

/// Whether two workouts went the same way (issue 23).
///
/// **The same route** means the same activity kind and mostly the same path, **in the same
/// direction** — an out-and-back done the other way round is a different route (decided with the
/// user). Judged on the cached sketches (``RouteSketch``, ~300 points each), so no series has to be
/// read.
///
/// Measured on the user's library (479 routes, 12,290 same-kind pairs with nearby ends):
/// - **Ordered overlap** separates cleanly: 7,798 pairs had ≥ 90%, a valley of ~50–90 pairs per 5%
///   between 55% and 80%, then everything else. Pairs at 80–90% were the same commute with a
///   different block near one end; at 70–80%, real variants (a shortcut through the middle, a
///   different finish). Threshold 80%, chosen by the user from drawings of each band.
/// - **Fréchet distance was rejected**: it's a worst case, so one GPS scribble at a destination
///   pushed identical walks past 300 m while genuinely different loops sat at 420 m.
/// - Ends of matching pairs: 99% within 98 m (start) and 73 m (finish); the few beyond 200 m were
///   one route carrying on past the other's end.
public enum RouteMatcher {
    /// Starts within this of each other, and finishes too.
    public static let endTolerance: Double = 200
    /// How near another route's point must be to count as on it.
    public static let pathTolerance: Double = 50
    /// Share of each route that must lie on the other, in order.
    public static let minimumOverlap: Double = 0.8
    /// The shorter route's length over the longer's. A cheap first cut: matching pairs measured
    /// ≥ 0.78 (1st percentile), the spread being GPS scribble rather than a different path.
    public static let minimumLengthRatio: Double = 0.75
    /// How far along the other route, as a share of its length, a point may be matched. Wide
    /// enough for a detour to shift things a little; narrow enough that a loop done backwards
    /// (same start and finish) doesn't match itself.
    static let alignmentWindow: Double = 0.15
    static let samples = 200

    /// A sketch prepared for matching: resampled to evenly spaced points, with its length.
    public struct Prepared: Sendable {
        let points: [Coordinate]
        /// The same points in metres north and "degrees east × metres per degree" — scaled once,
        /// so the inner loop of ``overlap(_:on:_:)`` is plain arithmetic. East–west gaps still need
        /// the cosine of the latitude, applied per comparison (``cosLatitude``): baking each
        /// point's own cosine in would be off by tens of metres this far from Greenwich.
        let east: [Double]
        let north: [Double]
        /// Cosine of the route's mean latitude.
        let cosLatitude: Double
        let length: Double

        public init?(_ coordinates: [Coordinate]) {
            guard coordinates.count >= 2 else { return nil }
            var cumulative = [0.0]
            cumulative.reserveCapacity(coordinates.count)
            for (a, b) in zip(coordinates, coordinates.dropFirst()) {
                cumulative.append(cumulative[cumulative.count - 1] + RouteMatcher.metres(a, b))
            }
            let total = cumulative[cumulative.count - 1]
            guard total > 0 else { return nil }
            var resampled: [Coordinate] = []
            resampled.reserveCapacity(RouteMatcher.samples)
            var segment = 0
            for index in 0..<RouteMatcher.samples {
                let target = total * Double(index) / Double(RouteMatcher.samples - 1)
                while segment < cumulative.count - 2 && cumulative[segment + 1] < target { segment += 1 }
                let span = cumulative[segment + 1] - cumulative[segment]
                let fraction = span > 0 ? (target - cumulative[segment]) / span : 0
                let a = coordinates[segment], b = coordinates[segment + 1]
                resampled.append(Coordinate(
                    latitude: a.latitude + (b.latitude - a.latitude) * fraction,
                    longitude: a.longitude + (b.longitude - a.longitude) * fraction))
            }
            points = resampled
            east = resampled.map { $0.longitude * RouteMatcher.metresPerDegree }
            north = resampled.map { $0.latitude * RouteMatcher.metresPerDegree }
            let meanLatitude = resampled.reduce(0) { $0 + $1.latitude } / Double(resampled.count)
            cosLatitude = cos(meanLatitude * .pi / 180)
            length = total
        }
    }

    public static func isSameRoute(_ a: Prepared, _ b: Prepared) -> Bool {
        guard min(a.length, b.length) / max(a.length, b.length) >= minimumLengthRatio,
              let aStart = a.points.first, let aEnd = a.points.last,
              let bStart = b.points.first, let bEnd = b.points.last,
              metres(aStart, bStart) <= endTolerance, metres(aEnd, bEnd) <= endTolerance
        else { return false }
        return overlap(a, on: b, atLeast: minimumOverlap) >= minimumOverlap
            && overlap(b, on: a, atLeast: minimumOverlap) >= minimumOverlap
    }

    /// The share of `route`'s points with a point of `other` within ``pathTolerance``, looking
    /// only at the part of `other` the same share of the way along.
    ///
    /// Searches outward from the matching position, where a hit usually is, and gives up as soon
    /// as `atLeast` is out of reach — most pairs with nearby ends still aren't the same route, and
    /// they fail early. With plain `Double` arrays (rather than SIMD, slow in debug builds) and the
    /// outward search, one lookup against 226 rides went from 0.42 s to 0.07 s (debug, measured).
    static func overlap(_ route: Prepared, on other: Prepared, atLeast required: Double = 0) -> Double {
        let count = route.east.count, otherCount = other.east.count
        guard count > 1, otherCount > 1 else { return 0 }
        let window = Int(alignmentWindow * Double(otherCount - 1))
        let tolerance = pathTolerance * pathTolerance
        let cosLatitude = route.cosLatitude
        let allowedMisses = Int(Double(count) * (1 - required))
        var hits = 0, misses = 0
        for index in 0..<count {
            let centre = Int((Double(index) / Double(count - 1) * Double(otherCount - 1)).rounded())
            let x = route.east[index], y = route.north[index]
            var hit = false
            for offset in 0...window {
                for candidate in offset == 0 ? [centre] : [centre - offset, centre + offset]
                where candidate >= 0 && candidate < otherCount {
                    let dx = (x - other.east[candidate]) * cosLatitude
                    let dy = y - other.north[candidate]
                    if dx * dx + dy * dy <= tolerance { hit = true; break }
                }
                if hit { break }
            }
            if hit { hits += 1 } else {
                misses += 1
                if misses > allowedMisses { break }
            }
        }
        return Double(hits) / Double(count)
    }

    static func overlap(_ route: [Coordinate], on other: [Coordinate]) -> Double {
        guard let route = Prepared(route), let other = Prepared(other) else { return 0 }
        return overlap(route, on: other)
    }

    static let metresPerDegree = 111_195.0

    /// Flat-earth distance: exact enough over the tens to hundreds of metres compared here, and
    /// several times cheaper than haversine across the ~10⁷ comparisons of a full library.
    static func metres(_ a: Coordinate, _ b: Coordinate) -> Double {
        let dy = (b.latitude - a.latitude) * metresPerDegree
        let dx = (b.longitude - a.longitude) * metresPerDegree * cos((a.latitude + b.latitude) / 2 * .pi / 180)
        return (dx * dx + dy * dy).squareRoot()
    }
}

/// Every time a workout's route has been done (issue 23): how often, the fastest, where this one
/// ranks, and each attempt for a chart. Ranked by **time**, like a Strava segment — GPS distance
/// for the same route varies by a few per cent, which would make a pace ranking jitter.
public struct RouteHistory: Equatable, Sendable {
    public struct Attempt: Identifiable, Equatable, Sendable {
        public let workoutID: String
        public let date: Date
        public let duration: TimeInterval
        public let distanceMeters: Double?

        public var id: String { workoutID }

        public var averageSpeedMetersPerSecond: Double? {
            guard let distanceMeters, distanceMeters > 0, duration > 0 else { return nil }
            return distanceMeters / duration
        }
    }

    /// The workout the history is for.
    public let workoutID: String
    /// Every attempt, this one included, oldest first.
    public let attempts: [Attempt]

    /// The quickest attempt; the earliest of equal times, as it was set first.
    public let fastest: Attempt

    public var count: Int { attempts.count }

    /// This workout's place by time, 1 being the fastest. Ties share the better place.
    public var rank: Int {
        guard let this = attempts.first(where: { $0.workoutID == workoutID }) else { return count }
        return attempts.filter { $0.duration < this.duration }.count + 1
    }

    /// The history of `workout`'s route among `candidates`, or `nil` if it has no route or no other
    /// workout matches it. Candidates of other kinds, or without a route, are skipped.
    ///
    /// `routes` are prepared once and reused: preparing the whole library takes longer than
    /// matching one workout against it (measured, 0.18 s for 479 routes, debug).
    public init?(for workout: Workout, routes: [String: RouteMatcher.Prepared], among candidates: [Workout]) {
        guard let target = routes[workout.id] else { return nil }
        let matches = candidates.filter { candidate in
            guard candidate.id != workout.id, candidate.kind == workout.kind,
                  let other = routes[candidate.id] else { return false }
            return RouteMatcher.isSameRoute(target, other)
        }
        let attempts = (matches + [workout])
            .map { Attempt(workoutID: $0.id, date: $0.start, duration: $0.duration, distanceMeters: $0.distanceMeters) }
            .sorted { $0.date < $1.date }
        // Oldest first, so the first of equal times wins.
        guard !matches.isEmpty, let fastest = attempts.min(by: { $0.duration < $1.duration }) else { return nil }
        workoutID = workout.id
        self.attempts = attempts
        self.fastest = fastest
    }
}
