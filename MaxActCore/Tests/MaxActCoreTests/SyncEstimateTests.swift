import Foundation
import Testing

@testable import MaxActCore

@Suite struct SyncEstimateTests {
    @Test("the real corpus is reported in hours, not an unreadable pile of seconds")
    func fullCorpus() {
        // ~2,867 workouts at 2.4 s each is close to two hours — the figure that shaped the
        // two-pass design, so it should read clearly.
        let description = SyncEstimate.describe(workoutCount: 2_867)
        #expect(description.contains("hours"))
        #expect(description == "about 1.9 hours")
    }

    @Test("units switch as the number grows", arguments: [
        (1, "seconds"), (20, "seconds"), (100, "minutes"), (1_000, "minutes"), (5_000, "hours"),
    ])
    func unitsScale(count: Int, unit: String) {
        #expect(SyncEstimate.describe(workoutCount: count).contains(unit))
    }

    @Test("an empty backlog reads as a moment rather than 'about 0 seconds'")
    func emptyBacklog() {
        #expect(SyncEstimate.describe(workoutCount: 0) == "a moment")
    }

    @Test("estimating by day count agrees with estimating by workout count")
    func dayAndWorkoutEstimatesAgree() {
        // A year of days, versus the workouts that year is expected to contain.
        let byDays = SyncEstimate.seconds(forDays: 365)
        let byCount = SyncEstimate.seconds(forWorkouts: Int(365 * SyncEstimate.workoutsPerDay))
        #expect(abs(byDays - byCount) < SyncEstimate.secondsPerWorkout)
    }

    @Test("the per-workout cost is the measured one, since the UI quotes it to the user")
    func costMatchesMeasurement() {
        // Phase 1 measured 2.3–2.5 s per workout across four request shapes. If this is ever
        // changed, the plan's time budgets need revisiting too.
        #expect(SyncEstimate.secondsPerWorkout == 2.4)
    }
}
