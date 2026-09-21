import Foundation

/// How long a sync will take, in words.
///
/// Sync is slow in a way that surprises people — the phone spends roughly the same time per
/// workout whatever you ask for — so every action that starts one should say what it will cost
/// *before* it runs, not in a progress bar afterwards.
public enum SyncEstimate {
    /// Measured in Phase 1 across four request shapes: 2.3–2.5 s per workout, essentially
    /// independent of whether routes or second-resolution metadata were requested. The cost is
    /// HealthKit query time on the phone, not transfer.
    public static let secondsPerWorkout = 2.4

    /// Measured over a 90-day window: 101 workouts, so ~1.12 a day. Used only where a count isn't
    /// known yet, such as estimating a date range before listing it.
    public static let workoutsPerDay = 1.12

    public static func seconds(forWorkouts count: Int) -> TimeInterval {
        Double(count) * secondsPerWorkout
    }

    public static func seconds(forDays days: Double) -> TimeInterval {
        days * workoutsPerDay * secondsPerWorkout
    }

    /// Rounded to whatever unit reads naturally: "about 40 seconds", "about 12 minutes",
    /// "about 1.9 hours". Deliberately vague — a precise figure would imply a precision the
    /// estimate doesn't have.
    public static func describe(_ seconds: TimeInterval) -> String {
        if seconds < 1 { return "a moment" }
        if seconds < 90 { return "about \(Int(seconds.rounded())) seconds" }
        if seconds < 5400 { return "about \(Int((seconds / 60).rounded())) minutes" }
        return "about \(String(format: "%.1f", seconds / 3600)) hours"
    }

    public static func describe(workoutCount count: Int) -> String {
        describe(seconds(forWorkouts: count))
    }
}
