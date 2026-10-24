import Charts
import MaxActCore
import SwiftUI

/// Every time this workout's route has been done (issue 23): how often, the fastest, where this
/// one ranks, and each attempt's time over the dates. Ranked by time, like a Strava segment.
struct RouteHistoryView: View {
    let history: RouteHistory
    let kind: ActivityKind
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Same Route", systemImage: "point.topleft.down.to.point.bottomright.curvepath")
                .font(.headline)
                .foregroundStyle(.secondary)

            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                // Not combined into one accessibility element: XCTest reads combined elements in
                // the inspector with an empty label (see the ≈ estimates), so each value is its own.
                GridRow {
                    Text("Done").foregroundStyle(.secondary)
                    Text("\(history.count) times").accessibilityIdentifier("RouteHistoryCount")
                }
                GridRow {
                    Text("Fastest").foregroundStyle(.secondary)
                    Text(describe(history.fastest)).accessibilityIdentifier("RouteHistoryFastest")
                }
                GridRow {
                    Text("This one").foregroundStyle(.secondary)
                    Text(rankText).accessibilityIdentifier("RouteHistoryRank")
                }
            }
            .font(.callout.monospacedDigit())

            chart
        }
    }

    private var rankText: String {
        history.rank == 1
            ? "Fastest of \(history.count)"
            : "\(Self.ordinal(history.rank)) of \(history.count)"
    }

    private func describe(_ attempt: RouteHistory.Attempt) -> String {
        WorkoutFormatting.duration(attempt.duration)
            + " · " + WorkoutFormatting.paceOrSpeed(metersPerSecond: attempt.averageSpeedMetersPerSecond, for: kind)
            + " · " + attempt.date.formatted(date: .abbreviated, time: .omitted)
    }

    private static func ordinal(_ number: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .ordinal
        return formatter.string(from: number as NSNumber) ?? "\(number)"
    }

    /// Time per attempt over the dates; this one in the route colour, the rest grey.
    private var chart: some View {
        Chart(history.attempts) { attempt in
            LineMark(x: .value("Date", attempt.date), y: .value("Minutes", attempt.duration / 60))
                .foregroundStyle(.secondary.opacity(0.4))
                .interpolationMethod(.linear)
            PointMark(x: .value("Date", attempt.date), y: .value("Minutes", attempt.duration / 60))
                .foregroundStyle(attempt.workoutID == history.workoutID ? tint : .secondary)
                .symbolSize(attempt.workoutID == history.workoutID ? 80 : 30)
        }
        .chartYAxisLabel("Minutes", position: .topLeading)
        // Leading, not the default trailing: the newest attempt — often this one, the
        // highlighted point — sits at the right edge and was drawn over the labels.
        .chartYAxis { AxisMarks(position: .leading) }
        .chartYScale(domain: .automatic(includesZero: false))
        .frame(height: 120)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Time on this route per attempt")
        .accessibilityValue(
            "\(history.count) attempts from \(history.attempts.first?.date.formatted(date: .abbreviated, time: .omitted) ?? "") "
                + "to \(history.attempts.last?.date.formatted(date: .abbreviated, time: .omitted) ?? "")")
    }
}
