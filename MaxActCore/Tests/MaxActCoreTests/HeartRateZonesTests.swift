import Foundation
import Testing

@testable import MaxActCore

@Suite struct HeartRateZonesTests {
    private let profile = HeartRateProfile(resting: 50, maximum: 190, curve: .male)!   // reserve 140
    private let t0 = Date(timeIntervalSince1970: 1_790_000_000)

    private func sample(_ seconds: TimeInterval, _ bpm: Double) -> HeartRateSample {
        HeartRateSample(date: t0.addingTimeInterval(seconds), minimum: bpm, average: bpm, maximum: bpm)
    }

    @Test("zones split heart-rate reserve at 50, 60, 70, 80 and 90%")
    func boundaries() {
        // Reserve 140: zones start at 120, 134, 148, 162 and 176 bpm.
        #expect(HeartRateZone.allCases.dropFirst().map { $0.lowerBound(profile: profile) } == [120, 134, 148, 162, 176])
        #expect(HeartRateZone.of(119, profile: profile) == .below)
        #expect(HeartRateZone.of(120, profile: profile) == .z1)
        #expect(HeartRateZone.of(147, profile: profile) == .z2)
        #expect(HeartRateZone.of(148, profile: profile) == .z3)
        #expect(HeartRateZone.of(175, profile: profile) == .z4)
        #expect(HeartRateZone.of(176, profile: profile) == .z5)
        #expect(HeartRateZone.of(205, profile: profile) == .z5, "above maximum is still the top zone")
    }

    @Test("each sample counts until the next, but a pause counts for nothing")
    func histogram() {
        let samples = [sample(0, 140), sample(5, 141), sample(10, 160),
                       sample(70, 100),              // 60 s after the last: a pause
                       sample(75, 100), sample(80, 100)]
        let histogram = HeartRateHistogram(samples)
        #expect(histogram.seconds == [140: 5, 141: 5, 100: 10], "160 bpm's 60 s gap isn't counted; the last sample has no duration")
        #expect(histogram.total == 20)
    }

    @Test("zone times come from the histogram, for any profile")
    func times() {
        let histogram = HeartRateHistogram(seconds: [100: 600, 125: 300, 150: 120, 180: 60])
        let times = HeartRateZone.times(histogram, profile: profile)
        #expect(times == [.below: 600, .z1: 300, .z3: 120, .z5: 60])
        // A higher resting rate moves the same heart rates down a zone or more.
        let fitter = HeartRateProfile(resting: 40, maximum: 190, curve: .male)!   // reserve 150
        #expect(HeartRateZone.times(histogram, profile: fitter)[.z3] == 120)       // 150 bpm: 73%
        var combined = histogram
        combined.add(HeartRateHistogram(seconds: [100: 30]))
        #expect(combined.seconds[100] == 630)
    }

    @Test("zone times group into periods, empty ones included")
    func byPeriod() {
        var calendar = WorkoutStatistics.trainingCalendar(timeZone: TimeZone(identifier: "America/Vancouver")!)
        calendar.locale = Locale(identifier: "en_US")
        func at(_ m: Int, _ d: Int) -> Date { calendar.date(from: DateComponents(year: 2026, month: m, day: d, hour: 12))! }
        let workouts: [(start: Date, histogram: HeartRateHistogram)] = [
            (at(9, 1), HeartRateHistogram(seconds: [150: 600])),
            (at(9, 2), HeartRateHistogram(seconds: [150: 300, 100: 60])),
            (at(9, 23), HeartRateHistogram(seconds: [180: 120])),
        ]
        let weeks = HeartRateZone.byPeriod(workouts, profile: profile, period: .week, through: at(10, 1), calendar: calendar)
        #expect(weeks.count == 5)
        #expect(weeks[0].times == [.z3: 900, .below: 60])
        #expect(weeks[1].times.isEmpty && weeks[2].times.isEmpty)
        #expect(weeks[3].times == [.z5: 120])
    }
}
