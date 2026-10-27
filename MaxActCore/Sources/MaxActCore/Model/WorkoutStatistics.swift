import Foundation

/// A calendar period that statistics are grouped by.
public enum StatisticsPeriod: String, CaseIterable, Identifiable, Sendable {
    case week, month, year

    public var id: Self { self }

    var component: Calendar.Component {
        switch self {
        case .week: .weekOfYear
        case .month: .month
        case .year: .year
        }
    }
}

/// A quantity that can be totalled across workouts.
public enum StatisticsMetric: String, CaseIterable, Identifiable, Sendable {
    case distance, duration, elevation, energy, count

    public var id: Self { self }

    /// The workout's contribution, or `nil` when it **should** have one and doesn't — which is
    /// different from having none to give. A strength session has no distance and isn't missing
    /// one; a ride without a distance is.
    func value(of workout: Workout) -> Double? {
        switch self {
        case .count: 1
        case .duration: workout.duration
        case .distance: workout.distanceMeters ?? (workout.kind.isDistanceBased ? nil : 0)
        case .elevation: workout.elevationAscendedMeters ?? (Self.expectsClimb(workout) ? nil : 0)
        case .energy: workout.activeEnergyKilocalories
        }
    }

    /// Only outdoor distance sports climb. An indoor ride reporting no ascent is not a gap.
    private static func expectsClimb(_ workout: Workout) -> Bool {
        workout.kind.isDistanceBased && workout.isIndoor != true
    }
}

/// Totals over one interval.
///
/// **Missing values are counted, never summed as zero.** Five of the 49 real workouts have no
/// ascent recorded; adding them in as 0 m would understate the total without saying so. Each
/// metric therefore carries how many workouts couldn't contribute, so the view can say "5 not
/// counted" beside the number.
public struct PeriodTotals: Identifiable, Equatable, Sendable {
    public let interval: DateInterval
    public private(set) var count = 0
    private var totals: [StatisticsMetric: Double] = [:]
    private var missing: [StatisticsMetric: Int] = [:]

    public var id: Date { interval.start }

    public init(interval: DateInterval, workouts: some Sequence<Workout> = []) {
        self.interval = interval
        for workout in workouts { add(workout) }
    }

    mutating func add(_ workout: Workout) {
        count += 1
        for metric in StatisticsMetric.allCases {
            if let value = metric.value(of: workout) {
                totals[metric, default: 0] += value
            } else {
                missing[metric, default: 0] += 1
            }
        }
    }

    /// The sum over workouts that have the value. See ``missingCount(_:)`` for the rest.
    public func total(_ metric: StatisticsMetric) -> Double { totals[metric] ?? 0 }

    /// How many workouts in the interval should have had `metric` but didn't.
    public func missingCount(_ metric: StatisticsMetric) -> Int { missing[metric] ?? 0 }
}

/// One year's running total, for the year-over-year comparison.
public struct YearProgress: Identifiable, Equatable, Sendable {
    public enum Role: String, Sendable {
        case current, previous, best
    }

    /// A point on the cumulative line. `date` is the day mapped into ``WorkoutStatistics/referenceYear``
    /// so every year plots against the same January-to-December axis.
    public struct Point: Equatable, Sendable {
        public let date: Date
        public let value: Double
    }

    public let year: Int
    /// Every role this year plays — this year can also be the best one.
    public let roles: Set<Role>
    public let points: [Point]
    public let total: Double

    public var id: Int { year }

    /// The running total as it stood on `date` (a date in ``WorkoutStatistics/referenceYear``) —
    /// for "by this date last year".
    public func value(onOrBefore date: Date) -> Double {
        points.last { $0.date <= date }?.value ?? 0
    }
}

/// One day's training, for the calendar heat map.
public struct DayTotal: Identifiable, Equatable, Sendable {
    public let day: Date
    public let count: Int
    public let duration: TimeInterval

    public var id: Date { day }
}

/// Runs of consecutive active days and weeks.
public struct Streaks: Equatable, Sendable {
    public let currentDays: Int
    public let longestDays: Int
    public let currentWeeks: Int
    public let longestWeeks: Int
}

/// A personal best for one activity kind.
public struct PersonalBest: Identifiable, Equatable, Sendable {
    public enum Category: String, CaseIterable, Sendable {
        case longestDistance, longestDuration, mostClimbing, fastest, mostEnergy
    }

    public let category: Category
    public let workoutID: String
    public let date: Date
    /// Metres, seconds, metres, metres per second or kilocalories, by ``category``.
    public let value: Double

    public var id: Category { category }
}

/// Period totals, year progression, consistency and personal bests — the statistics view's
/// arithmetic, kept here so period boundaries and the treatment of missing data are tested.
///
/// **A workout belongs to the day, week, month and year in which it started**, in the calendar's
/// time zone. A ride from 23:30 to 00:30 counts entirely on the first day, as the workout list
/// shows it.
public enum WorkoutStatistics {
    /// ISO weeks — starting Monday, week 1 containing the year's first Thursday — in the given
    /// time zone. Monday is the user's choice and the training-log convention; it is set here
    /// rather than read from the locale, which in Canada would start weeks on Sunday.
    public static func trainingCalendar(timeZone: TimeZone = .current) -> Calendar {
        var calendar = Calendar(identifier: .iso8601)
        calendar.timeZone = timeZone
        return calendar
    }

    /// The leap year every year's progression is plotted in, so 29 February has somewhere to go.
    public static let referenceYear = 2000

    /// Totals for every workout given.
    public static func overall(_ workouts: [Workout]) -> PeriodTotals {
        let start = workouts.map(\.start).min() ?? .distantPast
        let end = workouts.map(\.start).max() ?? start
        return PeriodTotals(interval: DateInterval(start: start, end: end), workouts: workouts)
    }

    /// The period containing `date`.
    public static func interval(
        of period: StatisticsPeriod, containing date: Date, calendar: Calendar
    ) -> DateInterval {
        calendar.dateInterval(of: period.component, for: date)
            ?? DateInterval(start: date, duration: 0)
    }

    /// Totals for the period containing `now`, even if it has no workouts.
    public static func current(
        _ period: StatisticsPeriod, of workouts: [Workout], now: Date, calendar: Calendar
    ) -> PeriodTotals {
        let interval = interval(of: period, containing: now, calendar: calendar)
        return PeriodTotals(interval: interval, workouts: workouts.filter { interval.contains($0.start) })
    }

    /// One entry per period from the first workout's period through the one containing `now`,
    /// **including empty periods** — a week off is a bar of zero, not a gap the axis closes up.
    public static func byPeriod(
        _ period: StatisticsPeriod, of workouts: [Workout], through now: Date, calendar: Calendar
    ) -> [PeriodTotals] {
        var buckets = periods(period, covering: workouts.map(\.start), through: now, calendar: calendar)
            .map { PeriodTotals(interval: $0) }
        let starts = buckets.map(\.interval.start)
        for workout in workouts {
            if let index = bucket(of: workout.start, starts: starts) { buckets[index].add(workout) }
        }
        return buckets
    }

    /// Every period from the one holding the earliest of `dates` through the one containing
    /// `now` (or the latest date, if later), empty ones included.
    static func periods(
        _ period: StatisticsPeriod, covering dates: [Date], through now: Date, calendar: Calendar
    ) -> [DateInterval] {
        guard let first = dates.min() else { return [] }
        let last = max(now, dates.max() ?? now)
        var intervals: [DateInterval] = []
        var cursor = interval(of: period, containing: first, calendar: calendar)
        while cursor.start <= last {
            intervals.append(cursor)
            // Step from the interval's end rather than adding a component to its start, which
            // drifts across DST changes and month lengths.
            cursor = interval(of: period, containing: cursor.end, calendar: calendar)
        }
        return intervals
    }

    /// The index of the last of `starts` (ascending) at or before `date`, by binary search.
    static func bucket(of date: Date, starts: [Date]) -> Int? {
        var low = 0, high = starts.count
        while low < high {
            let mid = (low + high) / 2
            if starts[mid] <= date { low = mid + 1 } else { high = mid }
        }
        return low > 0 ? low - 1 : nil
    }

    /// Running totals for this year, last year and the best year, like HealthFit's comparison.
    ///
    /// - This year is always included (if there are any workouts at all), running up to today.
    /// - Last year is included once the library reaches back into it, even if it's empty — a flat
    ///   line is the honest answer to "how did last year compare?".
    /// - The best year is the one with the highest total for `metric`, named once two years have
    ///   any. When that's this year or last year it isn't repeated; that year carries both roles.
    public static func yearProgression(
        _ workouts: [Workout], metric: StatisticsMetric, now: Date, calendar: Calendar
    ) -> [YearProgress] {
        guard let first = workouts.map(\.start).min() else { return [] }
        let thisYear = calendar.component(.year, from: now)
        let byYear = Dictionary(grouping: workouts) { calendar.component(.year, from: $0.start) }
        let totals = byYear.mapValues { $0.compactMap(metric.value).reduce(0, +) }

        var roles: [Int: Set<YearProgress.Role>] = [thisYear: [.current]]
        if calendar.component(.year, from: first) < thisYear {
            roles[thisYear - 1, default: []].insert(.previous)
        }
        // Highest total; on a tie, the more recent year. Only once two years have something in
        // them: with one, "best year" is true of it trivially and says nothing.
        let contenders = totals.filter { $0.value > 0 }
        if contenders.count > 1, let best = contenders.max(by: { ($0.value, $0.key) < ($1.value, $1.key) }) {
            roles[best.key, default: []].insert(.best)
        }

        return roles.keys.sorted(by: >).map { year in
            let ends = year == thisYear ? now : nil
            let points = cumulative(byYear[year] ?? [], metric: metric, year: year, through: ends, calendar: calendar)
            return YearProgress(year: year, roles: roles[year]!, points: points, total: points.last?.value ?? 0)
        }
    }

    /// A step line: zero on 1 January, a point on each day something was added, and a final
    /// point at the year's end — or at `through`, for the year still in progress.
    static func cumulative(
        _ workouts: [Workout], metric: StatisticsMetric, year: Int, through: Date?, calendar: Calendar
    ) -> [YearProgress.Point] {
        let byDay = Dictionary(grouping: workouts) { calendar.dateComponents([.month, .day], from: $0.start) }
            .mapValues { $0.compactMap(metric.value).reduce(0, +) }
        let ordered = byDay.sorted { ($0.key.month!, $0.key.day!) < ($1.key.month!, $1.key.day!) }

        var running = 0.0
        var points = [YearProgress.Point(date: reference(month: 1, day: 1, calendar: calendar), value: 0)]
        for (day, value) in ordered {
            running += value
            points.append(.init(date: reference(month: day.month!, day: day.day!, calendar: calendar), value: running))
        }
        let end = through.map { calendar.dateComponents([.month, .day], from: $0) }
        points.append(.init(
            date: reference(month: end?.month ?? 12, day: end?.day ?? 31, calendar: calendar), value: running))
        return points
    }

    /// `date`'s month and day in ``referenceYear``, for comparing against a ``YearProgress``.
    public static func referenceDate(for date: Date, calendar: Calendar) -> Date {
        let parts = calendar.dateComponents([.month, .day], from: date)
        return reference(month: parts.month ?? 1, day: parts.day ?? 1, calendar: calendar)
    }

    private static func reference(month: Int, day: Int, calendar: Calendar) -> Date {
        calendar.date(from: DateComponents(year: referenceYear, month: month, day: day)) ?? .distantPast
    }

    /// One entry per day from `start` through `end`, including rest days.
    public static func daily(
        _ workouts: [Workout], from start: Date, through end: Date, calendar: Calendar
    ) -> [DayTotal] {
        let byDay = Dictionary(grouping: workouts) { dayNumber($0.start, calendar) }
        var days: [DayTotal] = []
        var day = calendar.startOfDay(for: start)
        for number in dayNumber(start, calendar)...max(dayNumber(start, calendar), dayNumber(end, calendar)) {
            let workouts = byDay[number] ?? []
            days.append(DayTotal(day: day, count: workouts.count, duration: workouts.map(\.duration).reduce(0, +)))
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }
        return days
    }

    /// Consecutive days, and consecutive weeks, with at least one workout.
    ///
    /// A current streak **survives the day or week still in progress**: a streak through
    /// yesterday isn't broken at breakfast because today's ride hasn't happened yet.
    public static func streaks(_ workouts: [Workout], now: Date, calendar: Calendar) -> Streaks {
        let days = Set(workouts.map { dayNumber($0.start, calendar) })
        let weeks = Set(days.map(weekNumber))
        let today = dayNumber(now, calendar)
        return Streaks(
            currentDays: run(endingAt: today, in: days),
            longestDays: longestRun(in: days),
            currentWeeks: run(endingAt: weekNumber(today), in: weeks),
            longestWeeks: longestRun(in: weeks)
        )
    }

    /// Days since 1970-01-01 **in the calendar's time zone**, so a ride at 23:30 local time
    /// lands on the local day.
    ///
    /// Integer arithmetic rather than `Calendar.date(byAdding:)` per step: measured, the calendar
    /// version took 154 ms for a seven-year library even in a release build, and the statistics
    /// view recomputes on every filter change.
    static func dayNumber(_ date: Date, _ calendar: Calendar) -> Int {
        let local = date.timeIntervalSince1970 + Double(calendar.timeZone.secondsFromGMT(for: date))
        return Int((local / 86_400).rounded(.down))
    }

    /// Monday-based weeks: 1970-01-01 was a Thursday, so day 4 is the first Monday.
    static func weekNumber(_ day: Int) -> Int {
        Int((Double(day + 3) / 7).rounded(.down))
    }

    private static func run(endingAt end: Int, in set: Set<Int>) -> Int {
        // Allow the period in progress to be empty so far.
        var cursor = set.contains(end) ? end : end - 1
        var length = 0
        while set.contains(cursor) {
            length += 1
            cursor -= 1
        }
        return length
    }

    private static func longestRun(in set: Set<Int>) -> Int {
        var longest = 0, length = 0, previous: Int?
        for value in set.sorted() {
            length = previous == value - 1 ? length + 1 : 1
            longest = max(longest, length)
            previous = value
        }
        return longest
    }

    /// The shortest distance that can hold the speed record. A 300 m hop across a car park can
    /// average more than a real ride, and it says nothing about fitness.
    public static let minimumDistanceForSpeedRecord = 1000.0

    /// Bests for one activity kind, in ``PersonalBest/Category`` order. Categories that don't
    /// apply — distance for strength training — or that no workout has a value for are left out.
    ///
    /// Speed is ``Workout/effectiveSpeedMetersPerSecond``, so like the table it reads moving
    /// speed for sports that auto-pause and elapsed speed for those that don't — comparable
    /// within one kind, which is all a record compares.
    public static func personalBests(_ workouts: [Workout]) -> [PersonalBest] {
        PersonalBest.Category.allCases.compactMap { category in
            let candidates: [(Workout, Double)] = workouts.compactMap { workout in
                let value: Double? = switch category {
                case .longestDistance: workout.distanceMeters
                case .longestDuration: workout.duration
                case .mostClimbing: workout.elevationAscendedMeters
                case .mostEnergy: workout.activeEnergyKilocalories
                case .fastest: (workout.distanceMeters ?? 0) >= minimumDistanceForSpeedRecord
                    ? workout.effectiveSpeedMetersPerSecond : nil
                }
                guard let value, value > 0 else { return nil }
                return (workout, value)
            }
            // Highest value; on a tie, the earlier workout — it got there first.
            guard let best = candidates.max(by: { ($0.1, $1.0.start) < ($1.1, $0.0.start) }) else { return nil }
            return PersonalBest(category: category, workoutID: best.0.id, date: best.0.start, value: best.1)
        }
    }
}
