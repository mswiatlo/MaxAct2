import MaxActCore
import SwiftUI

/// Multi-selection: totals plus the batch actions, which is the whole point of selecting many.
struct SelectionSummaryView: View {
    let model: AppModel
    let items: [WorkoutListItem]

    private var aggregate: WorkoutAggregate { WorkoutAggregate(items.map(\.workout)) }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("\(items.count) Workouts Selected")
                .font(.title2.weight(.semibold))

            Grid(alignment: .leading, horizontalSpacing: 28, verticalSpacing: 10) {
                GridRow {
                    stat("Total Time", WorkoutFormatting.duration(aggregate.totalDuration))
                    stat("Total Distance", WorkoutFormatting.distance(aggregate.totalDistanceMeters))
                }
                GridRow {
                    stat("Total Energy", WorkoutFormatting.energy(kilocalories: aggregate.totalEnergyKilocalories))
                    stat("Total Ascent", WorkoutFormatting.elevation(meters: aggregate.totalElevationMeters))
                }
            }

            Divider()

            let pending = items.filter { !$0.stravaState.isOnStrava }.count
            let missingDetail = items.filter { !$0.hasDetail }.count
            VStack(alignment: .leading, spacing: 4) {
                Label("\(pending) not yet on Strava", systemImage: "circle.dashed")
                Label("\(missingDetail) without downloaded detail", systemImage: "arrow.down.circle.dotted")
            }
            .font(.callout)
            .foregroundStyle(.secondary)

            WorkoutActions(model: model, ids: Set(items.map(\.id)))
                .buttonStyle(.bordered)

            Spacer()
        }
        .padding(20)
        .navigationTitle("\(items.count) Selected")
    }

    private func stat(_ label: String, _ value: String) -> some View {
        StatCell(label: label, value: value)
    }
}
