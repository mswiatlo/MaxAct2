import Charts
import MaxActCore
import SwiftUI

/// Totals by period, a history chart, this year against previous ones, consistency, and personal
/// bests — issue 8, modelled on HealthFit's statistics.
///
/// All arithmetic is in `WorkoutStatistics`; this view only lays it out. It works from the rows
/// the search field leaves (so "commute" gives commute statistics), narrowed by its own activity
/// picker. Everything is computed in `body`, which re-runs only when those inputs change: the
/// hover state lives in the chart subviews, so pointing at a bar doesn't recompute the totals.
struct StatisticsView: View {
    @Bindable var model: AppModel

    /// The narrowest the statistics get. Every section reflows down to this.
    static let minimumWidth: CGFloat = 480

    /// `nil` for every activity.
    @State private var kindKey: String?
    @AppStorage("statistics.period") private var period: StatisticsPeriod = .week
    @AppStorage("statistics.metric") private var metric: StatisticsMetric = .distance

    private var workouts: [Workout] {
        model.visibleItems.map(\.workout).filter { kindKey == nil || $0.kind.storageKey == kindKey }
    }

    var body: some View {
        let workouts = self.workouts
        let calendar = WorkoutStatistics.trainingCalendar()
        let now = Date.now
        // Distance and climb mean nothing for a selection of strength sessions.
        let metrics = workouts.contains(where: \.kind.isDistanceBased)
            ? StatisticsMetric.allCases
            : [.duration, .energy, .count]
        let shownMetric = metrics.contains(metric) ? metric : .duration

        ScrollView {
            VStack(alignment: .leading, spacing: 32) {
                controls(metrics: metrics, shownMetric: shownMetric)

                if workouts.isEmpty {
                    ContentUnavailableView.search(text: model.searchText)
                } else {
                    TotalsSection(workouts: workouts, metrics: metrics, now: now, calendar: calendar)
                    HistorySection(
                        buckets: WorkoutStatistics.byPeriod(period, of: workouts, through: now, calendar: calendar),
                        period: $period, metric: shownMetric, calendar: calendar
                    )
                    YearSection(
                        years: WorkoutStatistics.yearProgression(workouts, metric: shownMetric, now: now, calendar: calendar),
                        metric: shownMetric,
                        today: WorkoutStatistics.referenceDate(for: now, calendar: calendar)
                    )
                    ConsistencySection(workouts: workouts, now: now, calendar: calendar)
                    BestsSection(model: model, workouts: workouts, kinds: model.presentKinds.map(\.kind))
                }
            }
            .padding(24)
            .frame(maxWidth: 960, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        // An explicit *ideal* width, so the split view sizes this pane from the space it's given
        // rather than from what the content would like. The content's ideal is its widest
        // single-line layout — the totals footnote alone wants 1,114pt, measured — and the split
        // view handed the statistics that (~920pt, capped by the 960 above) and the inspector
        // whatever was left: 40pt at first, and the three panes then overflowed the window, so
        // SwiftUI shifted them left and cut the sidebar off.
        .frame(minWidth: Self.minimumWidth, idealWidth: Self.minimumWidth, maxWidth: .infinity)
        .accessibilityIdentifier("StatisticsScroll")
        .navigationTitle("Statistics")
        .navigationSubtitle(subtitle(count: workouts.count))
    }

    private func subtitle(count: Int) -> String {
        let scope = kindKey.map { ActivityKind(storageKey: $0).displayName } ?? "All activities"
        let matching = model.searchText.isEmpty ? "" : " matching “\(model.searchText)”"
        return "\(scope) · \(count) workouts\(matching)"
    }

    /// Side by side when there's room, stacked when there isn't — the segmented picker alone is
    /// about 460pt, and a rigid row was part of what held the statistics at ~940pt wide.
    private func controls(metrics: [StatisticsMetric], shownMetric: StatisticsMetric) -> some View {
        let activity = Picker("Activity", selection: $kindKey) {
            Text("All Activities").tag(String?.none)
            Divider()
            ForEach(model.presentKinds, id: \.key) { entry in
                Label(entry.kind.displayName, systemImage: entry.kind.symbolName).tag(Optional(entry.key))
            }
        }
        .fixedSize()

        // Drives the history and year charts; the totals table shows every metric at once.
        let chart = Picker("Chart", selection: Binding(get: { shownMetric }, set: { metric = $0 })) {
            ForEach(metrics) { Text($0.title).tag($0) }
        }
        .pickerStyle(.segmented)
        .fixedSize()

        return ViewThatFits(in: .horizontal) {
            HStack(spacing: 16) { activity; Spacer(); chart }
            VStack(alignment: .leading, spacing: 10) { activity; chart }
        }
    }
}

// MARK: - Shared

private struct SectionHeader: View {
    let title: String
    let systemImage: String

    var body: some View {
        Label(title, systemImage: systemImage)
            .font(.title3.weight(.semibold))
    }
}

private struct Footnote: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

extension StatisticsPeriod {
    var title: String {
        switch self {
        case .week: "Weeks"
        case .month: "Months"
        case .year: "Years"
        }
    }

    var calendarComponent: Calendar.Component {
        switch self {
        case .week: .weekOfYear
        case .month: .month
        case .year: .year
        }
    }

    /// "Week of Oct 5, 2026", "October 2026", "2026".
    func label(for start: Date) -> String {
        switch self {
        case .week: "Week of \(start.formatted(date: .abbreviated, time: .omitted))"
        case .month: start.formatted(.dateTime.month(.wide).year())
        case .year: start.formatted(.dateTime.year())
        }
    }

    /// How many periods the history chart shows before it scrolls.
    var visibleCount: Int {
        switch self {
        case .week: 26
        case .month: 24
        case .year: 12
        }
    }
}

// MARK: - Totals

struct TotalsSection: View {
    let workouts: [Workout]
    let metrics: [StatisticsMetric]
    let now: Date
    let calendar: Calendar

    private func grid(_ rows: [(String, PeriodTotals)], spacing: CGFloat) -> some View {
        Grid(alignment: .trailing, horizontalSpacing: spacing, verticalSpacing: 8) {
                GridRow {
                    Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                    ForEach(columns) { metric in
                        Text(metric.title).font(.caption).foregroundStyle(.secondary)
                    }
                }
                ForEach(rows, id: \.0) { title, totals in
                    GridRow {
                        Text(title)
                            .fontWeight(title == "All time" ? .semibold : .regular)
                            .gridColumnAlignment(.leading)
                        ForEach(columns) { metric in
                            Text(WorkoutFormatting.total(totals.total(metric), metric))
                                .monospacedDigit()
                        }
                    }
                    .accessibilityElement(children: .combine)
                }
            }
    }

    /// Workouts first, then the rest, matching how a training log reads.
    private var columns: [StatisticsMetric] {
        [.count] + metrics.filter { $0 != .count }
    }

    var body: some View {
        let rows: [(String, PeriodTotals)] = [
            ("This week", WorkoutStatistics.current(.week, of: workouts, now: now, calendar: calendar)),
            ("This month", WorkoutStatistics.current(.month, of: workouts, now: now, calendar: calendar)),
            ("This year", WorkoutStatistics.current(.year, of: workouts, now: now, calendar: calendar)),
            ("All time", WorkoutStatistics.overall(workouts)),
        ]
        let allTime = rows[3].1

        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "Totals", systemImage: "sum")

            // Generous spacing when there's room, tight when there isn't.
            ViewThatFits(in: .horizontal) {
                grid(rows, spacing: 28)
                grid(rows, spacing: 12)
            }


            // Missing values are left out, not counted as zero — and saying so is the point.
            ForEach(metrics.filter { allTime.missingCount($0) > 0 }) { metric in
                let missing = allTime.missingCount(metric)
                Footnote(text: "\(metric.title) wasn't recorded for \(missing) workout\(missing == 1 ? "" : "s"); "
                         + "\(missing == 1 ? "it's" : "they're") left out of the \(metric.title.lowercased()) totals.")
            }
            Footnote(text: "Time is each workout's recorded duration: moving time for activities that pause "
                     + "automatically, such as most rides, and elapsed time for those that don't, such as walks. "
                     + "Weeks start on Monday; a workout counts on the day it started.")
        }
    }
}

// MARK: - History

struct HistorySection: View {
    let buckets: [PeriodTotals]
    @Binding var period: StatisticsPeriod
    let metric: StatisticsMetric
    let calendar: Calendar

    @State private var hovered: Date?

    /// The route colour, so statistics read as the same app as the map. `accentColor` came out
    /// grey inside a chart.
    static let tint = Color(RouteColor.default)

    /// The bucket under the pointer, or the current one.
    private var focused: PeriodTotals? {
        if let hovered, let bucket = buckets.last(where: { $0.interval.start <= hovered }) { return bucket }
        return buckets.last
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                SectionHeader(title: "History", systemImage: "chart.bar")
                Spacer()
                Picker("Period", selection: $period) {
                    ForEach(StatisticsPeriod.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .fixedSize()
                .labelsHidden()
            }

            if let focused {
                Text("\(period.label(for: focused.interval.start)): "
                     + "\(WorkoutFormatting.total(focused.total(metric), metric))"
                     + (metric == .count ? " workouts" : " · \(focused.count) workouts"))
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("HistoryFocus")
            }

            chart
                .frame(height: 200)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(metric.title) per \(period.rawValue)")
                .accessibilityValue("\(buckets.count) \(period.title.lowercased())")
        }
        // A new period scale starts unhovered rather than pointing at a stale date.
        .onChange(of: period) { hovered = nil }
    }

    private var chart: some View {
        Chart(buckets) { bucket in
            BarMark(
                x: .value("Period", bucket.interval.start, unit: period.calendarComponent, calendar: calendar),
                y: .value(metric.title, metric.chartValue(bucket.total(metric)))
            )
            .foregroundStyle(Self.tint.opacity(
                focused?.interval.start == bucket.interval.start ? 1 : 0.55))
        }
        .chartXSelection(value: $hovered)
        .chartYAxisLabel(metric.chartUnit)
        .chartScrollableAxes(buckets.count > period.visibleCount ? .horizontal : [])
        .chartXVisibleDomain(length: visibleLength)
        // Open on the most recent periods, as a training log does.
        .chartScrollPosition(initialX: initialScroll)
    }

    private var visibleLength: TimeInterval {
        guard let first = buckets.first, let last = buckets.last else { return 1 }
        let all = last.interval.end.timeIntervalSince(first.interval.start)
        let shown = buckets.suffix(period.visibleCount)
        guard let start = shown.first, buckets.count > period.visibleCount else { return all }
        return last.interval.end.timeIntervalSince(start.interval.start)
    }

    private var initialScroll: Date {
        buckets.suffix(period.visibleCount).first?.interval.start ?? .now
    }
}

// MARK: - Year by year

struct YearSection: View {
    let years: [YearProgress]
    let metric: StatisticsMetric
    /// Today, in the reference year.
    let today: Date

    private func label(_ year: YearProgress) -> String {
        let roles = [
            year.roles.contains(.current) ? "this year" : nil,
            year.roles.contains(.previous) ? "last year" : nil,
            year.roles.contains(.best) ? "best year" : nil,
        ].compactMap(\.self)
        return "\(year.year) (\(roles.joined(separator: ", ")))"
    }

    private func color(_ year: YearProgress) -> Color {
        if year.roles.contains(.current) { return HistorySection.tint }
        if year.roles.contains(.best) { return .yellow }
        return .gray
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "Year by Year", systemImage: "chart.line.uptrend.xyaxis")

            Chart(years) { year in
                ForEach(year.points, id: \.date) { point in
                    LineMark(
                        x: .value("Date", point.date),
                        y: .value(metric.title, metric.chartValue(point.value)),
                        series: .value("Year", label(year))
                    )
                    .interpolationMethod(.stepEnd)
                    .foregroundStyle(by: .value("Year", label(year)))
                    .lineStyle(StrokeStyle(lineWidth: year.roles.contains(.current) ? 2.5 : 1.5))
                }
            }
            .chartForegroundStyleScale(domain: years.map(label), range: years.map(color))
            .chartXScale(domain: yearDomain)
            .chartXAxis {
                AxisMarks(values: .stride(by: .month)) { _ in
                    AxisGridLine()
                    AxisValueLabel(format: .dateTime.month(.abbreviated), centered: true)
                }
            }
            .chartYAxisLabel(metric.chartUnit)
            .frame(height: 220)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Cumulative \(metric.title.lowercased()) by year")
            .accessibilityValue(years.map { "\(label($0)): \(WorkoutFormatting.total($0.total, metric))" }
                .joined(separator: "; "))

            ForEach(years) { year in
                Text(summary(year))
                    .font(.callout.monospacedDigit())
            }

            if years.count == 1 {
                Footnote(text: "Earlier years appear here once the library includes them. Sync older "
                         + "history from Health Auto Export to compare.")
            }
        }
    }

    private func summary(_ year: YearProgress) -> String {
        let total = WorkoutFormatting.total(year.total, metric)
        if year.roles.contains(.current) { return "\(year.year) so far: \(total)" }
        let byNow = WorkoutFormatting.total(year.value(onOrBefore: today), metric)
        return "\(year.year): \(total) — \(byNow) by \(today.formatted(.dateTime.month(.abbreviated).day()))"
    }

    private var yearDomain: ClosedRange<Date> {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let reference = WorkoutStatistics.referenceYear
        let start = calendar.date(from: DateComponents(year: reference, month: 1, day: 1)) ?? .distantPast
        // 1 January of the next year, so December gets a whole month of axis and its label.
        let end = calendar.date(from: DateComponents(year: reference + 1, month: 1, day: 1)) ?? .distantFuture
        return start...end
    }
}

// MARK: - Consistency

struct ConsistencySection: View {
    let workouts: [Workout]
    let now: Date
    let calendar: Calendar

    /// A year of weeks, ending with this one.
    private static let weeks = 53

    private enum Level: String, CaseIterable {
        case rest = "Rest"
        case short = "Under 30 min"
        case medium = "30–60 min"
        case long = "1–2 h"
        case veryLong = "Over 2 h"

        init(_ duration: TimeInterval) {
            switch duration {
            case ..<1: self = .rest
            case ..<1800: self = .short
            case ..<3600: self = .medium
            case ..<7200: self = .long
            default: self = .veryLong
            }
        }

        var color: Color {
            switch self {
            case .rest: .gray.opacity(0.22)
            case .short: .green.opacity(0.35)
            case .medium: .green.opacity(0.55)
            case .long: .green.opacity(0.78)
            case .veryLong: .green
            }
        }
    }

    /// Monday first, in the user's language.
    private var weekdayNames: [String] {
        let symbols = Calendar.current.shortWeekdaySymbols   // Sunday first
        return Array(symbols[1...] + symbols[..<1])
    }

    var body: some View {
        let thisWeek = WorkoutStatistics.interval(of: .week, containing: now, calendar: calendar).start
        let start = calendar.date(byAdding: .weekOfYear, value: -(Self.weeks - 1), to: thisWeek) ?? thisWeek
        let days = WorkoutStatistics.daily(workouts, from: start, through: now, calendar: calendar)
        let streaks = WorkoutStatistics.streaks(workouts, now: now, calendar: calendar)
        let active = days.count { $0.count > 0 }

        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "Consistency", systemImage: "calendar")

            heatMap(days)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Training calendar, past year")
                .accessibilityValue("Active on \(active) of \(days.count) days")

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 32) {
                    stat("Current streak", days: streaks.currentDays)
                    stat("Longest streak", days: streaks.longestDays)
                    stat("Weeks in a row", weeks: streaks.currentWeeks)
                    stat("Most weeks in a row", weeks: streaks.longestWeeks)
                }
                Grid(alignment: .leading, horizontalSpacing: 32, verticalSpacing: 10) {
                    GridRow {
                        stat("Current streak", days: streaks.currentDays)
                        stat("Weeks in a row", weeks: streaks.currentWeeks)
                    }
                    GridRow {
                        stat("Longest streak", days: streaks.longestDays)
                        stat("Most weeks in a row", weeks: streaks.longestWeeks)
                    }
                }
            }

            Footnote(text: "Active on \(active) of the last \(days.count) days. A streak isn't broken by "
                     + "today, or this week, until it's over.")
        }
    }

    private static let cell: CGFloat = 13
    private static let gap: CGFloat = 3

    /// Room for the weekday labels to the left of the grid.
    private static let labelColumn: CGFloat = 40

    /// GitHub's layout: a column per week, Monday at the top. Plain shapes rather than a Chart:
    /// `RectangleMark` on a date axis drew each day as a hairline, and a fixed grid of squares
    /// is all this is.
    ///
    /// Shows **as many recent weeks as fit**, up to a year. A full year is ~890pt of squares, and
    /// holding that width was most of what kept the statistics from giving way to the inspector.
    private func heatMap(_ days: [DayTotal]) -> some View {
        // `days` starts on a Monday, so every seven is a week; the last may be partial.
        let allWeeks = stride(from: 0, to: days.count, by: 7).map { Array(days[$0..<min($0 + 7, days.count)]) }

        return VStack(alignment: .leading, spacing: 6) {
            GeometryReader { geometry in
                let fit = Int((geometry.size.width - Self.labelColumn) / (Self.cell + Self.gap))
                grid(Array(allWeeks.suffix(max(4, fit))))
            }
            .frame(height: 14 + Self.gap + 7 * (Self.cell + Self.gap))

            HStack(spacing: 10) {
                ForEach(Level.allCases, id: \.self) { level in
                    HStack(spacing: 4) {
                        RoundedRectangle(cornerRadius: 2).fill(level.color)
                            .frame(width: Self.cell, height: Self.cell)
                        Text(level.rawValue).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func grid(_ weeks: [[DayTotal]]) -> some View {
        HStack(alignment: .top, spacing: Self.gap) {
            // Weekday labels, every other row, as GitHub does.
            VStack(alignment: .trailing, spacing: Self.gap) {
                Color.clear.frame(height: 14)
                ForEach(0..<7, id: \.self) { row in
                    Text(row.isMultiple(of: 2) ? weekdayNames[row] : "")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .frame(height: Self.cell)
                }
            }
            .frame(width: Self.labelColumn - Self.gap - 4, alignment: .trailing)
            .padding(.trailing, 4)

            ForEach(weeks.indices, id: \.self) { index in
                VStack(spacing: Self.gap) {
                    monthLabel(weeks, index)
                    ForEach(weeks[index]) { day in
                        RoundedRectangle(cornerRadius: 2)
                            .fill(Level(day.duration).color)
                            .frame(width: Self.cell, height: Self.cell)
                            .help(describe(day))
                    }
                }
                .frame(maxHeight: .infinity, alignment: .top)
            }
        }
    }

    /// The month's name over the first week that starts in it.
    private func monthLabel(_ weeks: [[DayTotal]], _ index: Int) -> some View {
        let month = weeks[index].first.map { calendar.component(.month, from: $0.day) }
        let previous = index > 0 ? weeks[index - 1].first.map { calendar.component(.month, from: $0.day) } : nil
        let label = month != previous ? weeks[index].first?.day.formatted(.dateTime.month(.abbreviated)) : nil
        return Text(label ?? "")
            .font(.caption2)
            .foregroundStyle(.secondary)
            .fixedSize()
            .frame(width: Self.cell, height: 14, alignment: .leading)
    }

    private func describe(_ day: DayTotal) -> String {
        let date = day.day.formatted(date: .abbreviated, time: .omitted)
        guard day.count > 0 else { return "\(date): rest" }
        return "\(date): \(day.count) workout\(day.count == 1 ? "" : "s"), "
            + WorkoutFormatting.total(day.duration, .duration)
    }

    private func stat(_ title: String, days: Int? = nil, weeks: Int? = nil) -> some View {
        let value = days.map { "\($0) day\($0 == 1 ? "" : "s")" } ?? weeks.map { "\($0) week\($0 == 1 ? "" : "s")" } ?? ""
        return VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title3.monospacedDigit())
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Personal bests

struct BestsSection: View {
    let model: AppModel
    let workouts: [Workout]
    /// In sidebar order: most frequent first.
    let kinds: [ActivityKind]

    var body: some View {
        let byKind = Dictionary(grouping: workouts, by: \.kind)
        let shown = kinds.filter { byKind[$0] != nil }

        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "Personal Bests", systemImage: "trophy")

            // A plain grid, not a `LazyVGrid`: lazy cards below the fold don't exist until scrolled
            // to, so VoiceOver and UI tests couldn't reach them. Two to a row when they fit, one
            // when they don't — e.g. beside the inspector.
            ViewThatFits(in: .horizontal) {
                cards(shown, byKind: byKind, perRow: 2)
                cards(shown, byKind: byKind, perRow: 1)
            }

            Footnote(text: "Click a best to show that workout. Fastest is average speed over 1 km or more.")
        }
    }

    private func cards(_ kinds: [ActivityKind], byKind: [ActivityKind: [Workout]], perRow: Int) -> some View {
        Grid(alignment: .topLeading, horizontalSpacing: 16, verticalSpacing: 16) {
            ForEach(Array(stride(from: 0, to: kinds.count, by: perRow)), id: \.self) { index in
                GridRow {
                    ForEach(kinds[index..<min(index + perRow, kinds.count)], id: \.self) { kind in
                        card(kind: kind, bests: WorkoutStatistics.personalBests(byKind[kind] ?? []))
                    }
                }
            }
        }
    }

    private func card(kind: ActivityKind, bests: [PersonalBest]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(kind.displayName, systemImage: kind.symbolName)
                .font(.headline)
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                ForEach(bests) { best in
                    GridRow {
                        Text(title(best.category))
                            .foregroundStyle(.secondary)
                        Button(value(best, kind: kind)) {
                            model.selection = [best.workoutID]
                            model.showsDetail = true
                        }
                        .buttonStyle(.link)
                        .monospacedDigit()
                        .help("Show this workout")
                        .accessibilityIdentifier("PersonalBest")
                        Text(best.date.formatted(date: .abbreviated, time: .omitted))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    .font(.callout)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 8))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(kind.displayName) personal bests")
    }

    private func title(_ category: PersonalBest.Category) -> String {
        switch category {
        case .longestDistance: "Longest"
        case .longestDuration: "Longest time"
        case .mostClimbing: "Most climbing"
        case .fastest: "Fastest"
        case .mostEnergy: "Most energy"
        }
    }

    private func value(_ best: PersonalBest, kind: ActivityKind) -> String {
        switch best.category {
        case .longestDistance: WorkoutFormatting.distance(best.value)
        case .longestDuration: WorkoutFormatting.duration(best.value)
        case .mostClimbing: WorkoutFormatting.elevationGain(meters: best.value)
        case .fastest: WorkoutFormatting.paceOrSpeed(metersPerSecond: best.value, for: kind)
        case .mostEnergy: WorkoutFormatting.energy(kilocalories: best.value)
        }
    }
}
