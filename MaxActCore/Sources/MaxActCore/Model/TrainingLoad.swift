import Foundation

/// What training load needs to know about the athlete's heart.
public struct HeartRateProfile: Equatable, Sendable {
    /// Banister's TRIMP weighting: how steeply effort counts as heart rate approaches maximum.
    /// Two published coefficients, fitted separately for men and women — a personal choice the
    /// user makes, never inferred.
    public enum Curve: String, CaseIterable, Sendable {
        case male, female

        public var coefficient: Double {
            switch self {
            case .male: 1.92
            case .female: 1.67
            }
        }
    }

    public let resting: Double
    public let maximum: Double
    public let curve: Curve

    /// `nil` unless the two rates leave a sensible range: TRIMP divides by their difference.
    public init?(resting: Double, maximum: Double, curve: Curve) {
        guard resting >= 25, maximum <= 240, maximum - resting >= 40 else { return nil }
        self.resting = resting
        self.maximum = maximum
        self.curve = curve
    }
}

/// One day of the training-load model: that day's load, and Fitness, Fatigue and Form after it.
public struct TrainingLoadDay: Identifiable, Equatable, Sendable {
    public let day: Date
    public let load: Double
    /// Chronic training load (CTL): the 42-day exponentially weighted average of daily load.
    public let fitness: Double
    /// Acute training load (ATL): the same over 7 days.
    public let fatigue: Double
    /// Training stress balance (TSB): yesterday's fitness minus yesterday's fatigue.
    public let form: Double

    public var id: Date { day }
}

/// Fitness, Fatigue and Form (CTL/ATL/TSB) from heart rate — issue 15.
///
/// Each workout's load is Banister's **TRIMP**: minutes × HRr × 0.64 × e^(k·HRr), where HRr is the
/// average heart rate as a fraction of the way from resting to maximum. It's computed from the
/// workout's *average* heart rate, because that's what every workout has; beat-by-beat TRIMP would
/// rate interval sessions higher, since the curve is steeper at the top. Comparable across one
/// person's workouts, which is all the model needs.
///
/// Daily loads feed two exponentially weighted averages, the usual Performance Manager shape:
/// `x(t) = x(t-1) + (load(t) - x(t-1)) / days`, with 42 days for fitness and 7 for fatigue. Both start
/// at zero on the first workout's day, so for the first six weeks or so fitness is still building
/// and reads low.
public enum TrainingLoad {
    public static let fitnessDays = 42.0
    public static let fatigueDays = 7.0

    /// A workout's TRIMP, or `nil` if it has no average heart rate to go on.
    public static func trimp(_ workout: Workout, profile: HeartRateProfile) -> Double? {
        guard let average = workout.averageHeartRate, average > 0 else { return nil }
        let reserve = min(max((average - profile.resting) / (profile.maximum - profile.resting), 0), 1)
        return workout.duration / 60 * reserve * 0.64 * exp(profile.curve.coefficient * reserve)
    }

    /// The model, one entry per day from the first workout's day through `now`, and how many
    /// workouts couldn't be counted for want of a heart rate.
    public static func days(
        _ workouts: [Workout], profile: HeartRateProfile, through now: Date, calendar: Calendar
    ) -> (days: [TrainingLoadDay], uncounted: Int) {
        var loads: [Int: Double] = [:]
        var uncounted = 0
        for workout in workouts {
            guard let load = trimp(workout, profile: profile) else { uncounted += 1; continue }
            loads[WorkoutStatistics.dayNumber(workout.start, calendar), default: 0] += load
        }
        guard let first = loads.keys.min() else { return ([], uncounted) }
        let last = max(WorkoutStatistics.dayNumber(now, calendar), loads.keys.max() ?? first)

        var days: [TrainingLoadDay] = []
        var fitness = 0.0, fatigue = 0.0
        var date = calendar.startOfDay(for: workouts.filter { WorkoutStatistics.dayNumber($0.start, calendar) == first }
            .map(\.start).min() ?? now)
        for number in first...last {
            let load = loads[number] ?? 0
            let form = fitness - fatigue
            fitness += (load - fitness) / fitnessDays
            fatigue += (load - fatigue) / fatigueDays
            days.append(TrainingLoadDay(day: date, load: load, fitness: fitness, fatigue: fatigue, form: form))
            date = calendar.date(byAdding: .day, value: 1, to: date) ?? date
        }
        return (days, uncounted)
    }

    /// A maximum heart rate to suggest: the highest any workout recorded. Real maximums are rarely
    /// reached in training, so this is a floor — the user should raise it if they know better.
    public static func suggestedMaximum(from workouts: [Workout]) -> Double? {
        workouts.compactMap(\.maximumHeartRate).max()
    }
}
