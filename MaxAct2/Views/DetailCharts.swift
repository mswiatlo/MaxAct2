import Charts
import MaxActCore
import SwiftUI

/// One time series against time.
///
/// Reused for heart rate, elevation and speed so the three cannot drift apart in how they handle
/// pauses, axes or accessibility.
struct SeriesChart: View {
    let title: String
    let systemImage: String
    let segments: [ChartSegment]
    let tint: Color

    /// Formats a value for the y-axis labels and for the spoken summary, so both read in the
    /// unit the athlete thinks in rather than in raw metres per second.
    let format: (Double) -> String

    /// Larger values plotted lower. For pace, where a smaller number is faster and an athlete
    /// expects up to mean quicker.
    var reversed: Bool = false

    private var values: [Double] {
        segments.flatMap(\.points).flatMap { point in
            // The band's extremes matter to the scale: a heart-rate axis sized to the averages
            // alone clips the very ranges the band exists to show.
            if let band = point.band { [band.lowerBound, band.upperBound] } else { [point.value] }
        }
    }

    var body: some View {
        if let low = values.min(), let high = values.max() {
            VStack(alignment: .leading, spacing: 6) {
                Label(title, systemImage: systemImage)
                    .font(.headline)
                    .foregroundStyle(.secondary)

                chart(low: low, high: high)
                    .frame(height: 130)
                    // One element with a summary, rather than several hundred unlabelled marks.
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(title)
                    .accessibilityValue(summary(low: low, high: high))
            }
        }
    }

    private func chart(low: Double, high: Double) -> some View {
        Chart {
            // Drawn per segment with a distinct series, which is what stops a line being drawn
            // across a pause — see `ChartSegment`.
            ForEach(segments) { segment in
                ForEach(segment.points, id: \.date) { point in
                    if let band = point.band {
                        AreaMark(
                            x: .value("Time", point.date),
                            yStart: .value("Lowest", band.lowerBound),
                            yEnd: .value("Highest", band.upperBound),
                            series: .value("Range", "band\(segment.id)")
                        )
                        .foregroundStyle(tint.opacity(0.18))
                    }
                }
            }
            ForEach(segments) { segment in
                ForEach(segment.points, id: \.date) { point in
                    LineMark(
                        x: .value("Time", point.date),
                        y: .value(title, point.value),
                        series: .value("Average", "line\(segment.id)")
                    )
                    .foregroundStyle(tint)
                    .lineStyle(StrokeStyle(lineWidth: 1.5))
                }
            }
        }
        // A little headroom, and never a zero baseline: heart rate starting at 0 flattens the
        // whole trace into the top of the chart. An array domain is how Charts takes a reversed
        // scale — a `ClosedRange` can't run downwards.
        .chartYScale(domain: domain(low: low, high: high))
        .chartYAxis {
            AxisMarks { value in
                AxisGridLine()
                AxisValueLabel {
                    if let number = value.as(Double.self) { Text(format(number)) }
                }
            }
        }
        .chartXAxis {
            AxisMarks { value in
                AxisGridLine()
                AxisValueLabel(format: .dateTime.hour().minute())
            }
        }
    }

    private func domain(low: Double, high: Double) -> [Double] {
        let span = high - low
        // A flat series — a treadmill's constant elevation — has no span to pad, and a zero-width
        // domain draws nothing at all.
        let margin = span > 0 ? span * 0.1 : max(1, abs(high) * 0.1)
        let bounds = [low - margin, high + margin]
        return reversed ? bounds.reversed() : bounds
    }

    private func summary(low: Double, high: Double) -> String {
        let span = segments.flatMap(\.points)
        guard let first = span.first?.date, let last = span.last?.date else { return "No data" }
        let minutes = Int((last.timeIntervalSince(first) / 60).rounded())
        let gaps = segments.count - 1
        let pauses = gaps > 0 ? ", \(gaps) pause\(gaps == 1 ? "" : "s")" : ""
        return "\(format(low)) to \(format(high)) over \(minutes) minutes\(pauses)"
    }
}

/// Per-kilometre splits.
///
/// A grid rather than a `Table`: there are rarely more than a couple of dozen rows, and a table
/// inside the detail pane's scroll view would mean nested scrolling. The bar is the point — a
/// column of numbers doesn't show which kilometre was the hard one.
struct SplitsTable: View {
    let splits: [Split]
    let kind: ActivityKind
    let tint: Color

    private var fastest: Double {
        splits.compactMap(\.speedMetersPerSecond).max() ?? 1
    }

    var body: some View {
        if !splits.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Label("Splits", systemImage: "flag.checkered")
                    .font(.headline)
                    .foregroundStyle(.secondary)

                Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 6) {
                    ForEach(splits) { split in
                        GridRow {
                            Text(label(for: split))
                                .font(.callout.monospacedDigit())
                                .foregroundStyle(split.isPartial ? .secondary : .primary)
                                .gridColumnAlignment(.trailing)

                            Text(WorkoutFormatting.paceOrSpeed(
                                metersPerSecond: split.speedMetersPerSecond, for: kind
                            ))
                            .font(.callout.monospacedDigit())

                            bar(for: split)

                            Text(WorkoutFormatting.duration(split.movingTime))
                                .font(.callout.monospacedDigit())
                                .foregroundStyle(.secondary)

                            Text(WorkoutFormatting.heartRate(split.averageHeartRate))
                                .font(.callout.monospacedDigit())
                                .foregroundStyle(.secondary)

                            Text(WorkoutFormatting.elevationGain(meters: split.elevationGainMeters))
                                .font(.callout.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        .accessibilityElement(children: .combine)
                    }
                }

                Text("Time is spent moving, so the splits add up to the workout's duration rather "
                     + "than to wall-clock time.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// The partial last split says its real distance, so its pace isn't read as a collapse.
    private func label(for split: Split) -> String {
        split.isPartial
            ? WorkoutFormatting.distance(split.distanceMeters)
            : "km \(split.index)"
    }

    /// Full scale is deliberately modest: the row has six columns and has to fit the detail
    /// pane's 440pt minimum without wrapping, and the bar is for comparison between rows rather
    /// than for reading a value off.
    private static let barWidth: Double = 90

    private func bar(for split: Split) -> some View {
        let fraction = (split.speedMetersPerSecond ?? 0) / fastest
        return RoundedRectangle(cornerRadius: 2)
            .fill(tint.opacity(split.isPartial ? 0.35 : 0.75))
            .frame(width: max(2, Self.barWidth * fraction), height: 8)
            // Already spoken by the row's other columns; a bar adds nothing to hear.
            .accessibilityHidden(true)
    }
}

// A splits table at the detail pane's *minimum* width, which is the case that has to hold: at the
// previous 300pt minimum these six columns wrapped and collided.
#Preview("Splits at minimum width") {
    SplitsTable(
        splits: [
            Split(index: 1, distanceMeters: 1000, movingTime: 150,
                  elevationGainMeters: 0, averageHeartRate: 115),
            Split(index: 2, distanceMeters: 1000, movingTime: 116,
                  elevationGainMeters: 29, averageHeartRate: 134),
            Split(index: 3, distanceMeters: 1000, movingTime: 252,
                  elevationGainMeters: 137, averageHeartRate: 159),
            Split(index: 4, distanceMeters: 663, movingTime: 148,
                  elevationGainMeters: 4, averageHeartRate: 103, isPartial: true),
        ],
        kind: .cycling,
        tint: Color(RouteColor.default)
    )
    .padding(20)
    .frame(width: 440)
}
