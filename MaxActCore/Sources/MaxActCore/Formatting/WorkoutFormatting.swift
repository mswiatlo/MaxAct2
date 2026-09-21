import Foundation

/// Display formatting for the canonical model.
///
/// Lives in the package rather than the views so it can be tested, and so the table and the
/// detail pane cannot drift apart on how a pace or a duration reads.
///
/// Everything returns an em dash for missing data rather than a zero: a strength session has no
/// distance, and "0.00 km" is a claim we have no basis for.
public enum WorkoutFormatting {
    public static let missing = "—"

    /// `1:23:45`, or `23:45` under an hour. Deliberately not `Duration.formatted` — workouts are
    /// read as clock times, and a column of mixed "1 hr 23 min" and "45 min" is hard to scan.
    public static func duration(_ seconds: TimeInterval?) -> String {
        guard let seconds, seconds.isFinite, seconds >= 0 else { return missing }
        let total = Int(seconds.rounded())
        let (hours, minutes, secs) = (total / 3600, (total % 3600) / 60, total % 60)
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, secs)
            : String(format: "%d:%02d", minutes, secs)
    }

    /// Kilometres with one decimal, switching to metres below 1 km so a 400 m walk isn't "0.4 km".
    public static func distance(_ meters: Double?) -> String {
        guard let meters, meters.isFinite, meters > 0 else { return missing }
        if meters < 1000 { return "\(Int(meters.rounded())) m" }
        return String(format: "%.2f km", meters / 1000)
    }

    /// Minutes per kilometre, as `5:30 /km`. The natural reading for foot sports.
    public static func pace(metersPerSecond: Double?) -> String {
        guard let speed = metersPerSecond, speed.isFinite, speed > 0.1 else { return missing }
        let secondsPerKilometer = 1000 / speed
        // Beyond about 30 min/km the number stops being meaningful — that's standing still.
        guard secondsPerKilometer < 1800 else { return missing }
        let minutes = Int(secondsPerKilometer) / 60
        let seconds = Int(secondsPerKilometer.rounded()) % 60
        return String(format: "%d:%02d /km", minutes, seconds)
    }

    /// Kilometres per hour, as `19.3 km/h`. The natural reading for wheeled sports.
    public static func speed(metersPerSecond: Double?) -> String {
        guard let speed = metersPerSecond, speed.isFinite, speed > 0 else { return missing }
        return String(format: "%.1f km/h", speed * 3.6)
    }

    /// Pace for foot sports, speed for wheeled ones — whichever the athlete actually thinks in.
    public static func paceOrSpeed(metersPerSecond: Double?, for kind: ActivityKind) -> String {
        switch kind {
        case .cycling, .indoorCycling, .rowing, .elliptical:
            speed(metersPerSecond: metersPerSecond)
        case .running, .walking, .hiking, .swimming:
            pace(metersPerSecond: metersPerSecond)
        case .strengthTraining, .functionalTraining, .yoga, .other:
            missing
        }
    }

    public static func energy(kilocalories: Double?) -> String {
        guard let kilocalories, kilocalories.isFinite, kilocalories > 0 else { return missing }
        return "\(Int(kilocalories.rounded())) kcal"
    }

    public static func heartRate(_ bpm: Double?) -> String {
        guard let bpm, bpm.isFinite, bpm > 0 else { return missing }
        return "\(Int(bpm.rounded())) bpm"
    }

    public static func elevation(meters: Double?) -> String {
        guard let meters, meters.isFinite, meters != 0 else { return missing }
        return "\(Int(meters.rounded())) m"
    }
}

extension Workout {
    /// Average speed over the workout: **distance ÷ duration**, in preference to Health Auto
    /// Export's own `avgSpeed`.
    ///
    /// This used to prefer `avgSpeed`, which made every pace read far too slow — a 3.73 km walk in
    /// 55:20 showed as 19:40 /km. Measuring five real workouts identified why: `avgSpeed` equals
    /// the **arithmetic mean of the per-point instantaneous speeds**, matching to six significant
    /// figures in all five cases. That mean includes every sample taken while stopped (6–27% of
    /// points), so it is biased low by 13–31% and the bias varies with how much the athlete
    /// stopped.
    ///
    /// `duration` is the better denominator because it is not wall-clock time — it already
    /// excludes paused segments, measured at 509–2,154 s against spans of 551–6,240 s. The result
    /// is both unbiased and stable: distance ÷ duration gave 5.37–5.55 m/s across four rides by
    /// the same rider, where `avgSpeed` scattered over 3.75–4.87 m/s.
    ///
    /// `avgSpeed` stays as a last resort for a workout with no distance, where nothing better
    /// exists; it is biased, but an em dash in every pace cell is worse.
    public var effectiveSpeedMetersPerSecond: Double? {
        if let distanceMeters, distanceMeters > 0, duration > 0 {
            return distanceMeters / duration
        }
        guard let averageSpeedMetersPerSecond, averageSpeedMetersPerSecond > 0 else { return nil }
        return averageSpeedMetersPerSecond
    }

    /// Average speed over the time actually spent moving, or `nil` without a stored route.
    ///
    /// Only materially different from ``effectiveSpeedMetersPerSecond`` for activities the watch
    /// doesn't auto-pause — see ``WorkoutSeries/movingTime(for:)``.
    public func movingSpeedMetersPerSecond(using series: WorkoutSeries) -> Double? {
        guard let distanceMeters, distanceMeters > 0,
              let moving = series.movingTime(for: kind), moving > 0
        else { return nil }
        return distanceMeters / moving
    }
}

/// Totals across a selection, for the "N workouts selected" summary.
public struct WorkoutAggregate: Sendable, Equatable {
    public let count: Int
    public let totalDuration: TimeInterval
    public let totalDistanceMeters: Double
    public let totalEnergyKilocalories: Double
    public let totalElevationMeters: Double

    public init(_ workouts: some Sequence<Workout>) {
        var count = 0
        var duration = 0.0, distance = 0.0, energy = 0.0, elevation = 0.0
        for workout in workouts {
            count += 1
            duration += workout.duration
            distance += workout.distanceMeters ?? 0
            energy += workout.activeEnergyKilocalories ?? 0
            elevation += workout.elevationAscendedMeters ?? 0
        }
        self.count = count
        totalDuration = duration
        totalDistanceMeters = distance
        totalEnergyKilocalories = energy
        totalElevationMeters = elevation
    }
}
