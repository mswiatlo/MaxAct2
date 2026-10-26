import Foundation

/// What a workout's route is coloured by (issue 31). Solid is the route colour; the others colour
/// each stretch by a value along the route. The heatmap always stays solid.
public enum RouteColoring: String, CaseIterable, Identifiable, Sendable {
    case solid, elevation, heartRate, pace

    public var id: Self { self }

    public var title: String {
        switch self {
        case .solid: "Solid"
        case .elevation: "Elevation"
        case .heartRate: "Heart Rate"
        case .pace: "Pace"
        }
    }

    public init(storageKey: String?) {
        self = storageKey.flatMap(Self.init(rawValue:)) ?? .solid
    }
}

/// How one stretch of a route is drawn: a step on the low-to-high ramp, a heart-rate zone, or
/// grey where there's no value (a pause, or no reading). The app turns these into colours.
public enum RouteShade: Hashable, Sendable {
    /// 0 is the lowest step, `RouteGradient.steps - 1` the highest.
    case ramp(Int)
    case zone(HeartRateZone)
    case missing
}

/// A route split into stretches of one shade each, for drawing a coloured route (issue 31).
///
/// Values are smoothed before shading, or GPS jitter breaks a route into hundreds of one-point
/// stretches: speed over a ±15 s window, elevation over ±10 s. The ramp spans the workout's 2nd to
/// 98th percentile, so one bad fix can't flatten the rest. Pauses (gaps over 30 s) are grey, as
/// is anything without a value.
public struct RouteGradient: Sendable, Equatable {
    public struct Run: Sendable, Equatable {
        /// Shares its first point with the previous run's last, so the line is unbroken.
        public let coordinates: [Coordinate]
        public let shade: RouteShade
    }

    /// The values the ramp spans, for a legend: lowest and highest. `nil` when shading by zone.
    public struct Range: Sendable, Equatable {
        public let low: Double
        public let high: Double
    }

    public static let steps = 10
    /// A gap longer than this between fixes is a pause, drawn grey.
    static let pauseGap: TimeInterval = 30
    /// Stretches shorter than this many points are merged into the one before.
    static let minimumRunPoints = 4

    public let runs: [Run]
    public let range: Range?

    /// `nil` for `.solid`, or a route too short to colour.
    public init?(_ coloring: RouteColoring, route: [RoutePoint], heartRate: [HeartRateSample],
                 profile: HeartRateProfile?) {
        guard coloring != .solid, route.count >= 2 else { return nil }
        let values: [Double?]
        switch coloring {
        case .solid: return nil
        case .elevation: values = Self.smoothed(route.map(\.altitudeMeters), times: route.map(\.timestamp), window: 10)
        case .pace: values = Self.speeds(route, window: 15)
        case .heartRate: values = Self.heartRates(at: route.map(\.timestamp), from: heartRate)
        }

        let shades: [RouteShade]
        if coloring == .heartRate, let profile {
            shades = values.map { $0.map { .zone(HeartRateZone.of($0, profile: profile)) } ?? .missing }
            range = nil
        } else {
            let known = values.compactMap { $0 }.sorted()
            guard !known.isEmpty else { return nil }
            var low = known[Int(Double(known.count - 1) * 0.02)]
            var high = known[Int(Double(known.count - 1) * 0.98)]
            // A flat route's few metres of sensor noise mustn't be stretched across the whole
            // ramp (measured: a 0.2 m spread did exactly that), so the range is at least
            // `minimumSpan` wide, centred on the values.
            let minimum = Self.minimumSpan(coloring)
            if high - low < minimum {
                let middle = (low + high) / 2
                (low, high) = (middle - minimum / 2, middle + minimum / 2)
            }
            let span = high - low
            shades = values.map { value in
                guard let value else { return .missing }
                let fraction = min(1, max(0, (value - low) / span))
                return .ramp(min(Self.steps - 1, Int(fraction * Double(Self.steps))))
            }
            range = Range(low: low, high: high)
        }
        runs = Self.runs(route, shades: shades)
    }

    /// Each run simplified for drawing into `pixels`, with one tolerance for the whole route —
    /// half a pixel of its bounding box — so the coloured line has the solid line's shape.
    public func simplified(fittingPixels pixels: Int) -> [Run] {
        let all = runs.flatMap(\.coordinates)
        guard pixels > 0, let bounds = CoordinateBounds(all) else { return runs }
        let scale = cos(bounds.centre.latitude * .pi / 180)
        let span = max(bounds.latitudeSpan, bounds.longitudeSpan * scale)
        let tolerance = span / Double(pixels) / 2
        return runs.map { Run(coordinates: RouteSimplifier.simplify($0.coordinates, tolerance: tolerance), shade: $0.shade) }
    }

    /// The narrowest range the ramp spans: 10 m, 0.5 m/s (about 25 s/km at a 5 min/km pace), 10 bpm.
    static func minimumSpan(_ coloring: RouteColoring) -> Double {
        switch coloring {
        case .elevation: 10
        case .pace: 0.5
        case .heartRate: 10
        case .solid: 0
        }
    }

    // MARK: - Values

    /// The mean of each value over ±`window` seconds, skipping missing ones.
    static func smoothed(_ values: [Double?], times: [Date], window: TimeInterval) -> [Double?] {
        var result: [Double?] = []
        result.reserveCapacity(values.count)
        var lo = 0, hi = 0, sum = 0.0, count = 0
        for i in values.indices {
            while hi < values.count, times[hi].timeIntervalSince(times[i]) <= window {
                if let v = values[hi] { sum += v; count += 1 }
                hi += 1
            }
            while times[i].timeIntervalSince(times[lo]) > window {
                if let v = values[lo] { sum -= v; count -= 1 }
                lo += 1
            }
            result.append(values[i] == nil || count == 0 ? nil : sum / Double(count))
        }
        return result
    }

    /// Speed at each fix: distance over ±`window` seconds, divided by the time. `nil` inside a
    /// pause, where there's no honest speed.
    static func speeds(_ route: [RoutePoint], window: TimeInterval) -> [Double?] {
        var cumulative = [0.0]
        for (a, b) in zip(route, route.dropFirst()) {
            cumulative.append(cumulative[cumulative.count - 1] + WorkoutSplits.distance(from: a.coordinate, to: b.coordinate))
        }
        var result: [Double?] = []
        var lo = 0, hi = 0
        for i in route.indices {
            while hi < route.count - 1, route[hi + 1].timestamp.timeIntervalSince(route[i].timestamp) <= window { hi += 1 }
            while route[i].timestamp.timeIntervalSince(route[lo].timestamp) > window { lo += 1 }
            let pausedHere = (i > 0 && route[i].timestamp.timeIntervalSince(route[i - 1].timestamp) > pauseGap)
            let seconds = route[hi].timestamp.timeIntervalSince(route[lo].timestamp)
            result.append(pausedHere || seconds <= 0 ? nil : (cumulative[hi] - cumulative[lo]) / seconds)
        }
        return result
    }

    /// The reading nearest each time, within 15 s. Readings must be in time order.
    static func heartRates(at times: [Date], from samples: [HeartRateSample]) -> [Double?] {
        guard !samples.isEmpty else { return times.map { _ in nil } }
        var j = 0
        return times.map { time in
            while j < samples.count - 1, samples[j + 1].date <= time { j += 1 }
            let candidates = [samples[j]] + (j + 1 < samples.count ? [samples[j + 1]] : [])
            let nearest = candidates.min { abs($0.date.timeIntervalSince(time)) < abs($1.date.timeIntervalSince(time)) }
            guard let nearest, abs(nearest.date.timeIntervalSince(time)) <= 15 else { return nil }
            return nearest.average
        }
    }

    // MARK: - Runs

    /// Consecutive points of one shade form a run; a pause gets a grey run of its own; runs too
    /// short to see are merged into the one before.
    static func runs(_ route: [RoutePoint], shades: [RouteShade]) -> [Run] {
        // The shade of each segment (point i to i+1): grey across a pause.
        var segmentShades: [RouteShade] = []
        for i in 0..<(route.count - 1) {
            let paused = route[i + 1].timestamp.timeIntervalSince(route[i].timestamp) > pauseGap
            segmentShades.append(paused ? .missing : shades[i])
        }
        // Merge short runs of segments into the previous run.
        var groups: [(shade: RouteShade, start: Int, end: Int)] = []   // segment indices, inclusive
        for (index, shade) in segmentShades.enumerated() {
            if let last = groups.last, last.shade == shade {
                groups[groups.count - 1].end = index
            } else {
                groups.append((shade, index, index))
            }
        }
        var merged: [(shade: RouteShade, start: Int, end: Int)] = []
        for group in groups {
            let length = group.end - group.start + 1
            if !merged.isEmpty, length < minimumRunPoints, group.shade != .missing {
                merged[merged.count - 1].end = group.end
            } else if let last = merged.last, last.shade == group.shade {
                merged[merged.count - 1].end = group.end
            } else {
                merged.append(group)
            }
        }
        return merged.map { group in
            Run(coordinates: route[group.start...(group.end + 1)].map(\.coordinate), shade: group.shade)
        }
    }
}
