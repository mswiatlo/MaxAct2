import Foundation
import Testing

@testable import MaxActCore

@Suite struct WorkoutStatisticsTests {
    private let zone = TimeZone(identifier: "America/Vancouver")!
    private var calendar: Calendar { WorkoutStatistics.trainingCalendar(timeZone: zone) }

    /// A local wall-clock time in Vancouver.
    private func at(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 12, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }

    private func ride(
        _ id: String, _ start: Date, km: Double? = 10, minutes: Double = 30,
        climb: Double? = 50, kcal: Double? = 300, kind: ActivityKind = .cycling, indoor: Bool? = false
    ) -> Workout {
        Workout(id: id, kind: kind, start: start, end: start.addingTimeInterval(minutes * 60),
                duration: minutes * 60, distanceMeters: km.map { $0 * 1000 },
                activeEnergyKilocalories: kcal, elevationAscendedMeters: climb, isIndoor: indoor)
    }

    // MARK: Periods

    @Test("weeks start on Monday, in the given time zone, whatever the locale")
    func isoWeeks() {
        // Sunday 11 October 2026, late evening: still the week that began Monday 5 October.
        let sunday = WorkoutStatistics.interval(of: .week, containing: at(2026, 10, 11, 23, 30), calendar: calendar)
        #expect(sunday.start == at(2026, 10, 5, 0))
        #expect(sunday.end == at(2026, 10, 12, 0))
        // A ride at 23:30 Vancouver time is 06:30 UTC the next day — but counts on the local day.
        let utcMonday = Date(timeIntervalSince1970: 1_791_786_600)  // 2026-10-12 06:30 UTC
        #expect(WorkoutStatistics.interval(of: .week, containing: utcMonday, calendar: calendar).start
                == at(2026, 10, 5, 0))
    }

    @Test("missing values are counted, not summed as zero — and only where a value was expected")
    func missingValues() {
        let totals = PeriodTotals(interval: DateInterval(start: at(2026, 1, 1), duration: 86_400 * 365), workouts: [
            ride("a", at(2026, 3, 1)),
            ride("b", at(2026, 3, 2), climb: nil, kcal: nil),               // outdoor ride, no ascent
            ride("c", at(2026, 3, 3), km: nil),                              // ride with no distance
            ride("d", at(2026, 3, 4), km: nil, climb: nil, kind: .strengthTraining, indoor: true),
            ride("e", at(2026, 3, 5), climb: nil, kind: .indoorCycling, indoor: true),
        ])
        #expect(totals.count == 5)
        #expect(totals.total(.distance) == 30_000)   // a, b, e
        #expect(totals.missingCount(.distance) == 1) // c; strength training has none to give
        #expect(totals.total(.elevation) == 100)     // a, c
        #expect(totals.missingCount(.elevation) == 1) // b; indoor and strength don't climb
        #expect(totals.missingCount(.energy) == 1)
        #expect(totals.total(.duration) == 5 * 1800)
        #expect(totals.total(.count) == 5)
    }

    @Test("empty periods stay in the series, up to the one containing now")
    func emptyPeriods() {
        let workouts = [ride("a", at(2026, 9, 1)), ride("b", at(2026, 9, 2)), ride("c", at(2026, 9, 23))]
        let weeks = WorkoutStatistics.byPeriod(.week, of: workouts, through: at(2026, 10, 12), calendar: calendar)
        #expect(weeks.map(\.count) == [2, 0, 0, 1, 0, 0, 0])
        #expect(weeks.first?.interval.start == at(2026, 8, 31, 0))
        #expect(weeks.last?.interval.contains(at(2026, 10, 12)) == true)

        let months = WorkoutStatistics.byPeriod(.month, of: workouts, through: at(2026, 10, 12), calendar: calendar)
        #expect(months.map(\.count) == [3, 0])
        #expect(WorkoutStatistics.byPeriod(.year, of: [], through: .now, calendar: calendar).isEmpty)
    }

    @Test("weekly buckets stay contiguous across a daylight-saving change")
    func daylightSaving() {
        // Vancouver leaves DST on 1 November 2026: that week is 169 hours long.
        let workouts = [ride("a", at(2026, 10, 20)), ride("b", at(2026, 11, 3))]
        let weeks = WorkoutStatistics.byPeriod(.week, of: workouts, through: at(2026, 11, 20), calendar: calendar)
        for (week, next) in zip(weeks, weeks.dropFirst()) {
            #expect(week.interval.end == next.interval.start)
            #expect(calendar.component(.weekday, from: next.interval.start) == 2)  // Monday
            #expect(calendar.component(.hour, from: next.interval.start) == 0)
        }
        #expect(weeks.map(\.count).reduce(0, +) == 2)
    }

    @Test("the current period is reported even when nothing happened in it")
    func currentPeriod() {
        let workouts = [ride("a", at(2026, 9, 1)), ride("b", at(2026, 10, 6))]
        #expect(WorkoutStatistics.current(.week, of: workouts, now: at(2026, 10, 12), calendar: calendar).count == 0)
        #expect(WorkoutStatistics.current(.month, of: workouts, now: at(2026, 10, 12), calendar: calendar).count == 1)
        #expect(WorkoutStatistics.current(.year, of: workouts, now: at(2026, 10, 12), calendar: calendar).count == 2)
    }

    // MARK: Year progression

    @Test("this year, last year and the best year, each as a running total")
    func yearProgression() throws {
        let workouts = [
            ride("old1", at(2024, 3, 1), km: 100), ride("old2", at(2024, 6, 1), km: 100),
            ride("last", at(2025, 5, 1), km: 50),
            ride("now1", at(2026, 2, 1), km: 20), ride("now2", at(2026, 2, 1, 18), km: 5),
            ride("now3", at(2026, 7, 4), km: 10),
        ]
        let years = WorkoutStatistics.yearProgression(workouts, metric: .distance, now: at(2026, 10, 12), calendar: calendar)
        #expect(years.map(\.year) == [2026, 2025, 2024])
        #expect(years.map(\.roles) == [[.current], [.previous], [.best]])
        #expect(years.map(\.total) == [35_000, 50_000, 200_000])

        // Two rides on one day are one step; the line starts at zero on 1 January and stops today.
        let current = try #require(years.first)
        #expect(current.points.map(\.value) == [0, 25_000, 35_000, 35_000])
        let reference = WorkoutStatistics.referenceYear
        #expect(current.points.first?.date == calendar.date(from: DateComponents(year: reference, month: 1, day: 1)))
        #expect(current.points.last?.date == calendar.date(from: DateComponents(year: reference, month: 10, day: 12)))
        // "By this date last year": 2025's total as of 12 October, and as of 30 April.
        let today = WorkoutStatistics.referenceDate(for: at(2026, 10, 12), calendar: calendar)
        #expect(years[1].value(onOrBefore: today) == 50_000)
        #expect(years[1].value(onOrBefore: WorkoutStatistics.referenceDate(for: at(2026, 4, 30), calendar: calendar)) == 0)
        // A finished year runs to 31 December.
        #expect(years[1].points.last?.date == calendar.date(from: DateComponents(year: reference, month: 12, day: 31)))
    }

    @Test("a best year that is also this or last year isn't drawn twice")
    func bestYearNotRepeated() {
        let workouts = [ride("a", at(2025, 5, 1), km: 10), ride("b", at(2026, 5, 1), km: 90)]
        let years = WorkoutStatistics.yearProgression(workouts, metric: .distance, now: at(2026, 10, 12), calendar: calendar)
        #expect(years.map(\.year) == [2026, 2025])
        #expect(years.map(\.roles) == [[.current, .best], [.previous]])

        // A library that starts this year has no "last year" to compare with.
        let fresh = WorkoutStatistics.yearProgression([workouts[1]], metric: .distance, now: at(2026, 10, 12), calendar: calendar)
        #expect(fresh.map(\.year) == [2026])
        // …and with one year of data, "best" would be trivially true, so it isn't claimed.
        #expect(fresh.first?.roles == [.current])

        // An empty last year is still shown once the library reaches back past it.
        let gap = WorkoutStatistics.yearProgression([ride("x", at(2024, 1, 5)), workouts[1]],
                                                    metric: .count, now: at(2026, 10, 12), calendar: calendar)
        #expect(gap.map(\.year) == [2026, 2025])
        #expect(gap[1].total == 0)
        #expect(gap[0].roles == [.current, .best])  // ties 2024's one workout; the more recent wins
    }

    @Test("29 February has a place on the shared axis")
    func leapDay() {
        let years = WorkoutStatistics.yearProgression([ride("leap", at(2024, 2, 29))], metric: .count,
                                                      now: at(2024, 12, 31), calendar: calendar)
        #expect(years.first?.points.map(\.date).contains(
            calendar.date(from: DateComponents(year: WorkoutStatistics.referenceYear, month: 2, day: 29))!) == true)
    }

    // MARK: Consistency

    @Test("daily totals include rest days")
    func daily() {
        let days = WorkoutStatistics.daily([ride("a", at(2026, 10, 1)), ride("b", at(2026, 10, 1, 18)),
                                            ride("c", at(2026, 10, 3)),
                                            // 06:30 UTC on the 4th; the local day is the 3rd.
                                            ride("late", at(2026, 10, 3, 23, 30))],
                                           from: at(2026, 10, 1), through: at(2026, 10, 4), calendar: calendar)
        #expect(days.map(\.count) == [2, 0, 2, 0])
        #expect(days[0].duration == 3600)
        #expect(days.first?.day == at(2026, 10, 1, 0))
    }

    @Test("a streak survives the day still in progress, and breaks after a missed one")
    func streaks() {
        // An older five-day run, then four days ending yesterday.
        let older = (1...5).map { ride("o\($0)", at(2026, 9, $0)) }
        let recent = (8...11).map { ride("r\($0)", at(2026, 10, $0)) }
        let streaks = WorkoutStatistics.streaks(older + recent, now: at(2026, 10, 12, 7), calendar: calendar)
        #expect(streaks.currentDays == 4)
        #expect(streaks.longestDays == 5)
        // Weeks of 31 Aug (1–5 Sep) and of 5 Oct (8–11 Oct); this week hasn't started yet.
        #expect(streaks.currentWeeks == 1)
        #expect(streaks.longestWeeks == 1)

        let broken = WorkoutStatistics.streaks(recent, now: at(2026, 10, 13), calendar: calendar)
        #expect(broken.currentDays == 0)
        #expect(broken.currentWeeks == 1)  // last week counted; this week isn't over

        let weekly = (0..<6).map { ride("w\($0)", at(2026, 9, 1).addingTimeInterval(Double($0) * 7 * 86_400)) }
        #expect(WorkoutStatistics.streaks(weekly, now: at(2026, 10, 7), calendar: calendar).longestWeeks == 6)
        #expect(WorkoutStatistics.streaks([], now: .now, calendar: calendar)
                == Streaks(currentDays: 0, longestDays: 0, currentWeeks: 0, longestWeeks: 0))
    }

    // MARK: Personal bests

    @Test("personal bests: the speed record needs a real distance, and ties go to the first")
    func personalBests() throws {
        let bests = WorkoutStatistics.personalBests([
            ride("long", at(2026, 5, 1), km: 80, minutes: 200, climb: 900),
            ride("quick", at(2026, 5, 2), km: 20, minutes: 40, climb: 10),       // 30 km/h
            ride("hop", at(2026, 5, 3), km: 0.3, minutes: 0.5, climb: 0),        // 36 km/h, too short
            ride("again", at(2026, 5, 4), km: 80, minutes: 220, climb: 900, kcal: 2000),
        ])
        let byCategory = Dictionary(uniqueKeysWithValues: bests.map { ($0.category, $0) })
        #expect(byCategory[.longestDistance]?.workoutID == "long")   // tie: earlier wins
        #expect(byCategory[.mostClimbing]?.workoutID == "long")
        #expect(byCategory[.longestDuration]?.workoutID == "again")
        #expect(byCategory[.mostEnergy]?.workoutID == "again")
        let fastest = try #require(byCategory[.fastest])
        #expect(fastest.workoutID == "quick")
        #expect(abs(fastest.value - 20_000.0 / 2400) < 1e-9)

        // Categories with nothing to show are left out rather than reported as zero.
        let strength = WorkoutStatistics.personalBests([
            ride("s", at(2026, 5, 1), km: nil, climb: nil, kind: .strengthTraining, indoor: true),
        ])
        #expect(strength.map(\.category) == [.longestDuration, .mostEnergy])
    }

    @Test("a seven-year library summarises quickly")
    func scale() {
        let workouts = SampleData.workouts(count: 2_867)
        let now = workouts.map(\.start).max()!
        let elapsed = ContinuousClock().measure {
            _ = WorkoutStatistics.byPeriod(.week, of: workouts, through: now, calendar: calendar)
            _ = WorkoutStatistics.yearProgression(workouts, metric: .distance, now: now, calendar: calendar)
            _ = WorkoutStatistics.streaks(workouts, now: now, calendar: calendar)
            _ = WorkoutStatistics.daily(workouts, from: now.addingTimeInterval(-371 * 86_400), through: now, calendar: calendar)
            _ = WorkoutStatistics.personalBests(workouts)
        }
        print("statistics over 2,867 workouts: \(elapsed)")
        // ~60 ms alone, but over 200 ms once in a parallel `swift test` (issue 43). The limit
        // catches a 10× regression without failing on a busy machine.
        #expect(elapsed < .seconds(1), "took \(elapsed)")
    }
}
