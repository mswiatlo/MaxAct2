import Foundation
import Testing

@testable import MaxActCore

@Suite struct TrainingLoadTests {
    private let zone = TimeZone(identifier: "America/Vancouver")!
    private var calendar: Calendar { WorkoutStatistics.trainingCalendar(timeZone: zone) }
    private func at(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 12) -> Date {
        calendar.date(from: DateComponents(year: y, month: m, day: d, hour: h))!
    }
    private func workout(_ id: String, _ start: Date, minutes: Double = 60, average: Double? = 150) -> Workout {
        Workout(id: id, kind: .cycling, start: start, end: start.addingTimeInterval(minutes * 60),
                duration: minutes * 60, averageHeartRate: average)
    }
    private let male = HeartRateProfile(resting: 50, maximum: 190, curve: .male)!

    @Test("TRIMP matches Banister's formula, for both curves")
    func trimp() throws {
        // Reference values computed independently: 60 min at 150 bpm, resting 50, maximum 190.
        let ride = workout("a", at(2026, 9, 1))
        #expect(abs(try #require(TrainingLoad.trimp(ride, profile: male)) - 108.0954) < 0.001)
        let female = try #require(HeartRateProfile(resting: 50, maximum: 190, curve: .female))
        #expect(abs(try #require(TrainingLoad.trimp(ride, profile: female)) - 90.4179) < 0.001)
    }

    @Test("no heart rate means no load — counted as such, not as zero")
    func missingHeartRate() {
        #expect(TrainingLoad.trimp(workout("a", at(2026, 9, 1), average: nil), profile: male) == nil)
        let result = TrainingLoad.days([workout("a", at(2026, 9, 1)), workout("b", at(2026, 9, 2), average: nil)],
                                       profile: male, through: at(2026, 9, 3), calendar: calendar)
        #expect(result.uncounted == 1)
        #expect(result.days.count == 3)
    }

    @Test("a heart rate below resting adds nothing; above maximum is capped")
    func clamped() throws {
        #expect(TrainingLoad.trimp(workout("easy", at(2026, 9, 1), average: 40), profile: male) == 0)
        let flat = try #require(TrainingLoad.trimp(workout("max", at(2026, 9, 1), average: 190), profile: male))
        let over = try #require(TrainingLoad.trimp(workout("over", at(2026, 9, 1), average: 205), profile: male))
        #expect(flat == over)
    }

    @Test("fitness builds over 42 days, fatigue over 7, and form is yesterday's difference")
    func averages() throws {
        // A constant load of 100 a day. Reference values from the same recurrence, computed apart.
        let profile = try #require(HeartRateProfile(resting: 50, maximum: 190, curve: .male))
        let hourLoad = try #require(TrainingLoad.trimp(workout("x", at(2026, 1, 1)), profile: profile))
        let perDay = 100 / hourLoad * 60   // minutes at 150 bpm that make a load of 100
        let workouts = (0..<42).map { workout("d\($0)", at(2026, 1, 1).addingTimeInterval(Double($0) * 86_400), minutes: perDay) }
        let days = TrainingLoad.days(workouts, profile: profile, through: at(2026, 2, 11), calendar: calendar).days
        #expect(days.count == 42)
        #expect(abs(days[6].fatigue - 66.0083) < 0.01)
        #expect(abs(days[41].fitness - 63.6544) < 0.01)
        // Form on a day is the balance *before* that day's training.
        #expect(abs(days[10].form - (days[9].fitness - days[9].fatigue)) < 1e-9)
        #expect(days[0].form == 0)
        #expect(days[41].form < 0, "Training every day leaves fatigue above fitness.")
    }

    @Test("days without workouts are in the series, and form recovers during rest")
    func rest() {
        let result = TrainingLoad.days([workout("a", at(2026, 9, 1), minutes: 240)], profile: male,
                                       through: at(2026, 9, 15), calendar: calendar)
        #expect(result.days.count == 15)
        #expect(result.days.first?.day == at(2026, 9, 1, 0))
        #expect(result.days[1].form < 0)
        #expect(result.days.last!.form > result.days[1].form, "Fatigue fades faster than fitness.")
    }

    @Test("a profile needs a sensible range")
    func profile() {
        #expect(HeartRateProfile(resting: 60, maximum: 80, curve: .male) == nil)
        #expect(HeartRateProfile(resting: 10, maximum: 190, curve: .male) == nil)
        #expect(HeartRateProfile(resting: 55, maximum: 185, curve: .female) != nil)
    }

    @Test("the suggested maximum is the highest any workout reached")
    func suggestedMaximum() {
        let w = [Workout(id: "a", kind: .cycling, start: .now, end: .now, duration: 60, maximumHeartRate: 171),
                 Workout(id: "b", kind: .cycling, start: .now, end: .now, duration: 60, maximumHeartRate: 182)]
        #expect(TrainingLoad.suggestedMaximum(from: w) == 182)
        #expect(TrainingLoad.suggestedMaximum(from: []) == nil)
    }

    @Test("seven years of workouts model quickly")
    func scale() {
        let workouts = SampleData.workouts(count: 2_867)
        let now = workouts.map(\.start).max()!
        let clock = ContinuousClock()
        let elapsed = clock.measure { _ = TrainingLoad.days(workouts, profile: male, through: now, calendar: calendar) }
        print("training load over 2,867 workouts: \(elapsed)")
        #expect(elapsed < .milliseconds(300), "took \(elapsed)")
    }
}
