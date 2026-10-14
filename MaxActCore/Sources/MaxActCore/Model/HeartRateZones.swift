import Foundation

/// Seconds spent at each whole heart rate during one workout — what zone times are summed from,
/// whatever the zones turn out to be.
///
/// Each sample counts for the time until the next one, **except across a gap of more than
/// ``maxGap``**: measured on the user's 418 workouts, samples arrive every 5 s (99% within 13 s),
/// but 682 gaps over 30 s add up to 30.7 h of the 275 h total — pauses, which would otherwise be
/// credited to whatever the heart rate was before the athlete stopped.
public struct HeartRateHistogram: Codable, Sendable, Equatable {
    public static let maxGap: TimeInterval = 30

    /// Seconds by whole bpm.
    public private(set) var seconds: [Int: TimeInterval]

    public init(seconds: [Int: TimeInterval] = [:]) {
        self.seconds = seconds
    }

    public init(_ samples: [HeartRateSample]) {
        var seconds: [Int: TimeInterval] = [:]
        for (sample, next) in zip(samples, samples.dropFirst()) {
            let gap = next.date.timeIntervalSince(sample.date)
            guard gap > 0, gap <= Self.maxGap, sample.average > 0 else { continue }
            seconds[Int(sample.average.rounded()), default: 0] += gap
        }
        self.seconds = seconds
    }

    public var total: TimeInterval { seconds.values.reduce(0, +) }

    public mutating func add(_ other: HeartRateHistogram) {
        seconds.merge(other.seconds, uniquingKeysWith: +)
    }
}

/// Five heart-rate zones by **heart-rate reserve** (Karvonen) — the share of the way from resting
/// to maximum, the approach Apple Watch uses — plus time below the first. The user's choice.
public enum HeartRateZone: Int, CaseIterable, Identifiable, Sendable, Comparable {
    case below, z1, z2, z3, z4, z5

    public var id: Int { rawValue }

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

    /// The zone's lower edge as a fraction of reserve.
    public var lowerFraction: Double {
        switch self {
        case .below: 0
        case .z1: 0.5
        case .z2: 0.6
        case .z3: 0.7
        case .z4: 0.8
        case .z5: 0.9
        }
    }

    public var title: String {
        switch self {
        case .below: "Below Z1"
        case .z1: "Zone 1"
        case .z2: "Zone 2"
        case .z3: "Zone 3"
        case .z4: "Zone 4"
        case .z5: "Zone 5"
        }
    }

    /// The zone a heart rate falls in.
    public static func of(_ bpm: Double, profile: HeartRateProfile) -> HeartRateZone {
        let fraction = (bpm - profile.resting) / (profile.maximum - profile.resting)
        return allCases.last { fraction >= $0.lowerFraction } ?? .below
    }

    /// The bpm at which the zone starts, for labelling.
    public func lowerBound(profile: HeartRateProfile) -> Int {
        Int((profile.resting + lowerFraction * (profile.maximum - profile.resting)).rounded(.up))
    }

    /// Seconds per zone from a histogram — instant, so changing the profile never needs a reload.
    public static func times(_ histogram: HeartRateHistogram, profile: HeartRateProfile) -> [HeartRateZone: TimeInterval] {
        histogram.seconds.reduce(into: [:]) { result, entry in
            result[of(Double(entry.key), profile: profile), default: 0] += entry.value
        }
    }
}

extension HeartRateZone {
    /// Zone times per period, from the first workout's period through the one containing `now`,
    /// empty periods included — the same buckets as ``WorkoutStatistics/byPeriod(_:of:through:calendar:)``.
    public static func byPeriod(
        _ workouts: [(start: Date, histogram: HeartRateHistogram)], profile: HeartRateProfile,
        period: StatisticsPeriod, through now: Date, calendar: Calendar
    ) -> [(interval: DateInterval, times: [HeartRateZone: TimeInterval])] {
        guard let first = workouts.map(\.start).min() else { return [] }
        var buckets: [(interval: DateInterval, histogram: HeartRateHistogram)] = []
        var cursor = WorkoutStatistics.interval(of: period, containing: first, calendar: calendar)
        let last = max(now, workouts.map(\.start).max() ?? now)
        while cursor.start <= last {
            buckets.append((cursor, HeartRateHistogram()))
            cursor = WorkoutStatistics.interval(of: period, containing: cursor.end, calendar: calendar)
        }
        for workout in workouts {
            guard let index = buckets.lastIndex(where: { $0.interval.start <= workout.start }) else { continue }
            buckets[index].histogram.add(workout.histogram)
        }
        return buckets.map { ($0.interval, times($0.histogram, profile: profile)) }
    }
}
