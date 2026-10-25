import Charts
import MaxActCore
import SwiftUI

/// Every time this workout's route has been done (issue 23): how often, the fastest, where this
/// one ranks, and each attempt's time over the dates. Ranked by time, like a Strava segment.
struct RouteHistoryView: View {
    let history: RouteHistory
    let kind: ActivityKind
    let tint: Color
    /// Opens another attempt, when one is clicked in the chart.
    let open: (String) -> Void

    /// The attempt under the pointer, shown with its exact date and time.
    @State private var hovered: RouteHistory.Attempt?

    /// How near, on screen, the pointer must be to a point to pick it. In points, so it feels
    /// the same however many attempts are squeezed in.
    private static let hitRadius: CGFloat = 12

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

    /// The attempt drawn nearest `location`, if within ``hitRadius``.
    private func attempt(near location: CGPoint, proxy: ChartProxy, in geometry: GeometryProxy) -> RouteHistory.Attempt? {
        guard let plotFrame = proxy.plotFrame else { return nil }
        let origin = geometry[plotFrame].origin
        let nearest = history.attempts.compactMap { attempt -> (RouteHistory.Attempt, CGFloat)? in
            guard let x = proxy.position(forX: attempt.date),
                  let y = proxy.position(forY: attempt.duration / 60) else { return nil }
            return (attempt, hypot(origin.x + x - location.x, origin.y + y - location.y))
        }.min { $0.1 < $1.1 }
        guard let nearest, nearest.1 <= Self.hitRadius else { return nil }
        return nearest.0
    }

    private func tooltip(for attempt: RouteHistory.Attempt) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(attempt.date, format: .dateTime.weekday(.abbreviated).day().month(.abbreviated).year().hour().minute())
            Text(WorkoutFormatting.duration(attempt.duration)
                 + " · " + WorkoutFormatting.paceOrSpeed(metersPerSecond: attempt.averageSpeedMetersPerSecond, for: kind))
                .foregroundStyle(.secondary)
            if attempt.workoutID != history.workoutID {
                Text("Click to open").font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .font(.caption.monospacedDigit())
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(.regularMaterial, in: .rect(cornerRadius: 6))
        .accessibilityIdentifier("RouteHistoryTooltip")
    }

    /// Time per attempt over the dates; this one in the route colour, the rest grey.
    private var chart: some View {
        Chart(history.attempts) { attempt in
            LineMark(x: .value("Date", attempt.date), y: .value("Minutes", attempt.duration / 60))
                .foregroundStyle(.secondary.opacity(0.4))
                .interpolationMethod(.linear)
            PointMark(x: .value("Date", attempt.date), y: .value("Minutes", attempt.duration / 60))
                .foregroundStyle(attempt.workoutID == history.workoutID ? tint : .secondary)
                .symbolSize(attempt.workoutID == history.workoutID || attempt == hovered ? 80 : 30)
                .annotation(
                    position: .top, spacing: 6,
                    overflowResolution: .init(x: .fit(to: .chart), y: .fit(to: .chart))
                ) {
                    if attempt == hovered { tooltip(for: attempt) }
                }
        }
        .chartOverlay { proxy in
            GeometryReader { geometry in
                Rectangle()
                    .fill(.clear)
                    .contentShape(.rect)
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let location):
                            hovered = attempt(near: location, proxy: proxy, in: geometry)
                            if hovered != nil { NSCursor.pointingHand.set() } else { NSCursor.arrow.set() }
                        case .ended:
                            hovered = nil
                            NSCursor.arrow.set()
                        }
                    }
                    .onTapGesture { location in
                        guard let attempt = attempt(near: location, proxy: proxy, in: geometry),
                              attempt.workoutID != history.workoutID else { return }
                        hovered = nil
                        NSCursor.arrow.set()
                        open(attempt.workoutID)
                    }
            }
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
