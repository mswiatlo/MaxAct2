import Charts
import MaxActCore
import SwiftUI

extension HeartRateZone {
    /// Cool to hot, the convention every training app follows.
    var color: Color {
        switch self {
        case .below: .gray
        case .z1: .blue
        case .z2: .green
        case .z3: .yellow
        case .z4: .orange
        case .z5: .red
        }
    }
}

/// Time in each heart-rate zone, by period (issue 15). Zones are shares of heart-rate reserve
/// (Karvonen), from the Training Load profile. Follows the statistics' period, activity picker and
/// search.
///
/// The histograms come from the same cached pass over the series as the route sketches, so on a
/// first visit they arrive late. Until then the section lays out with empty data — the same height
/// — so nothing below it moves when they arrive.
struct HeartRateZonesSection: View {
    let model: AppModel
    let workouts: [Workout]
    let period: StatisticsPeriod
    let now: Date
    let calendar: Calendar

    @State private var hovered: Date?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "Heart-Rate Zones", systemImage: "heart")

            if let profile = model.settings.heartRateProfile {
                content(profile)
            } else {
                Text("Set your heart-rate details under Training Load to see time in each zone.")
                    .foregroundStyle(.secondary)
            }
        }
        .onChange(of: period) { hovered = nil }
    }

    @ViewBuilder
    private func content(_ profile: HeartRateProfile) -> some View {
        let preparing = model.routeSketchProgress != nil
        let measured = preparing ? [] : workouts.compactMap { workout in
            model.heartRateHistograms[workout.id].map { (start: workout.start, histogram: $0) }
        }
        // Empty buckets while preparing, so the chart keeps its axis and height.
        let buckets = HeartRateZone.byPeriod(measured.isEmpty ? workouts.map { ($0.start, HeartRateHistogram()) } : measured,
                                             profile: profile, period: period, through: now, calendar: calendar)
        // The period under the pointer; otherwise the whole span, summed (user's choice) — not the
        // latest period, which read as if it were the hovered one.
        let hoveredBucket = hovered.flatMap { hovered in buckets.last { $0.interval.start <= hovered } }
        let times = hoveredBucket?.times ?? buckets.reduce(into: [:]) { total, bucket in
            total.merge(bucket.times, uniquingKeysWith: +)
        }
        let span: String = {
            if let hoveredBucket { return period.label(for: hoveredBucket.interval.start) }
            guard let first = buckets.first, let last = buckets.last else { return "" }
            return first.interval.start == last.interval.start ? period.label(for: first.interval.start)
                : "\(period.label(for: first.interval.start)) – \(period.label(for: last.interval.start))"
        }()

        Text(buckets.isEmpty ? " " : "\(span) · " + HeartRateZoneBreakdown.describe(times.values.reduce(0, +)))
            .font(.callout.monospacedDigit())
            .foregroundStyle(.secondary)
            .accessibilityIdentifier("ZonesFocus")

        HeartRateZoneBreakdown(times: times, profile: profile)

        chart(buckets)
            .frame(height: 160)
            .overlay {
                if preparing {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Reading heart rate…").font(.callout).foregroundStyle(.secondary)
                    }
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Time in heart-rate zones per \(period.rawValue)")
            .accessibilityValue("\(buckets.count) \(period.title.lowercased())")

        Footnote(text: "From \(measured.count) of \(workouts.count) workouts — those with detail downloaded. "
                 + "Zones are shares of heart-rate reserve, between resting (\(Int(profile.resting))) and maximum "
                 + "(\(Int(profile.maximum))) bpm. Each reading counts until the next; gaps over "
                 + "\(Int(HeartRateHistogram.maxGap)) s, such as pauses, count nothing.")
    }

    private func chart(_ buckets: [(interval: DateInterval, times: [HeartRateZone: TimeInterval])]) -> some View {
        let visibleCount = period.visibleCount
        let shown = buckets.suffix(visibleCount)
        let length = (buckets.last?.interval.end).map { end in
            end.timeIntervalSince((buckets.count > visibleCount ? shown.first : buckets.first)?.interval.start ?? end)
        } ?? 1
        return Chart {
            ForEach(buckets, id: \.interval.start) { bucket in
                ForEach(HeartRateZone.allCases) { zone in
                    BarMark(
                        x: .value("Period", bucket.interval.start, unit: period.calendarComponent, calendar: calendar),
                        y: .value("Hours", (bucket.times[zone] ?? 0) / 3600)
                    )
                    .foregroundStyle(by: .value("Zone", zone.title))
                }
            }
        }
        .chartForegroundStyleScale(domain: HeartRateZone.allCases.map(\.title),
                                   range: HeartRateZone.allCases.map(\.color))
        .chartLegend(.hidden)
        .chartYAxisLabel("hours")
        .chartXSelection(value: $hovered)
        .chartScrollableAxes(buckets.count > visibleCount ? .horizontal : [])
        .chartXVisibleDomain(length: length)
        .chartScrollPosition(initialX: shown.first?.interval.start ?? now)
    }
}

/// Time in each zone, hottest first, with each zone's bpm range, its time and its share, and a bar.
/// Shared by the statistics (one period) and the inspector (one workout).
struct HeartRateZoneBreakdown: View {
    let times: [HeartRateZone: TimeInterval]
    let profile: HeartRateProfile

    var body: some View {
        let total = times.values.reduce(0, +)
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
            ForEach(HeartRateZone.allCases.reversed()) { zone in
                let time = times[zone] ?? 0
                let share = total > 0 ? time / total : 0
                GridRow {
                    // The row's one accessibility element, labelled in full. Modifiers on a
                    // `GridRow` apply to each cell, so the other cells are hidden instead.
                    HStack(spacing: 6) {
                        Circle().fill(zone.color).frame(width: 8, height: 8)
                        Text(zone.title)
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(Text(verbatim: [zone.title, Self.range(zone, profile: profile), Self.describe(time),
                                                        share.formatted(.percent.precision(.fractionLength(0)))]
                        .joined(separator: ", ")))
                    .accessibilityIdentifier("ZoneRow")
                    Group {
                        Text(Self.range(zone, profile: profile))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                        Text(Self.describe(time))
                            .monospacedDigit()
                            .gridColumnAlignment(.trailing)
                        Text(share.formatted(.percent.precision(.fractionLength(0))))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                            .gridColumnAlignment(.trailing)
                        GeometryReader { proxy in
                            Capsule().fill(zone.color.opacity(0.7))
                                .frame(width: max(0, proxy.size.width * share))
                        }
                        .frame(height: 6)
                    }
                    .accessibilityHidden(true)
                }
                .font(.callout)
            }
        }
    }

    static func range(_ zone: HeartRateZone, profile: HeartRateProfile) -> String {
        let lower = zone.lowerBound(profile: profile)
        let next = HeartRateZone(rawValue: zone.rawValue + 1)?.lowerBound(profile: profile)
        switch (zone, next) {
        case (.below, let next?): return "under \(next) bpm"
        case (_, let next?): return "\(lower)–\(next - 1) bpm"
        default: return "\(lower)+ bpm"
        }
    }

    /// "3 hrs, 20 mins", or "45 mins".
    static func describe(_ seconds: TimeInterval) -> String {
        WorkoutFormatting.hoursAndMinutes(seconds)
    }
}
