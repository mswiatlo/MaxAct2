import MapKit
import MaxActCore
import SwiftUI

/// The third column: nothing, one workout, or an aggregate of many.
struct DetailPane: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        content
            // Without a minimum the split view squeezes this to ~196pt, which is too narrow for
            // a map or a stats grid.
            .navigationSplitViewColumnWidth(min: 300, ideal: 360)
    }

    @ViewBuilder
    private var content: some View {
        switch model.selectedItems.count {
        case 0:
            ContentUnavailableView(
                "No Workout Selected",
                systemImage: "sidebar.right",
                description: Text("Select a workout to see its route and heart rate.")
            )
        case 1:
            WorkoutDetailView(item: model.selectedItems[0])
        default:
            SelectionSummaryView(items: model.selectedItems)
        }
    }
}

/// Phase 5 replaces this with the full map, charts and splits. For now it shows the stats we
/// already have and the route if one has been downloaded.
struct WorkoutDetailView: View {
    let item: WorkoutListItem

    @Environment(AppModel.self) private var model
    @State private var series: WorkoutSeries?

    private var workout: Workout { item.workout }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header

                if let series, !series.route.isEmpty {
                    routeMap(series)
                } else if workout.hasRoute && !item.hasDetail {
                    notDownloadedNotice
                }

                statsGrid
            }
            .padding(20)
        }
        .navigationTitle(workout.kind.displayName)
        .task(id: item.id) {
            series = await model.seriesStore.loadIfAvailable(item.id)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(workout.kind.displayName, systemImage: workout.kind.symbolName)
                .font(.title2.weight(.semibold))
            Text(workout.start, format: .dateTime.weekday(.wide).day().month(.wide).year().hour().minute())
                .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                StravaStateBadge(state: item.stravaState)
                if let place = item.placeLabel {
                    Text("· \(place)").foregroundStyle(.secondary)
                }
                if let source = workout.sourceName {
                    Text("· \(source)").foregroundStyle(.secondary)
                }
            }
            .font(.callout)
        }
    }

    private func routeMap(_ series: WorkoutSeries) -> some View {
        // Simplified for display too: drawing 12,645 points into a few hundred on-screen pixels
        // costs a great deal and shows nothing extra.
        let coordinates = RouteSimplifier.simplify(series.route.map(\.coordinate), fittingPixels: 900)
            .map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) }

        return Map {
            MapPolyline(coordinates: coordinates)
                .stroke(.tint, style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
        }
        .frame(height: 280)
        .clipShape(.rect(cornerRadius: 10))
        .accessibilityLabel("Route map with \(coordinates.count) points")
    }

    private var notDownloadedNotice: some View {
        GroupBox {
            Label(
                "The route and heart-rate detail for this workout haven't been downloaded yet.",
                systemImage: "arrow.down.circle.dotted"
            )
            .foregroundStyle(.secondary)
        }
    }

    private var statsGrid: some View {
        Grid(alignment: .leading, horizontalSpacing: 28, verticalSpacing: 10) {
            GridRow {
                stat("Duration", WorkoutFormatting.duration(workout.duration))
                stat("Distance", WorkoutFormatting.distance(workout.distanceMeters))
                stat("Energy", WorkoutFormatting.energy(kilocalories: workout.activeEnergyKilocalories))
            }
            GridRow {
                stat("Avg Pace", WorkoutFormatting.paceOrSpeed(
                    metersPerSecond: workout.effectiveSpeedMetersPerSecond, for: workout.kind))
                stat("Avg HR", WorkoutFormatting.heartRate(workout.averageHeartRate))
                stat("Max HR", WorkoutFormatting.heartRate(workout.maximumHeartRate))
            }
            GridRow {
                stat("Ascent", WorkoutFormatting.elevation(meters: workout.elevationAscendedMeters))
                stat("Descent", WorkoutFormatting.elevation(meters: workout.elevationDescendedMeters))
                if let series {
                    stat("Samples", "\(series.route.count) pts · \(series.heartRate.count) HR")
                }
            }
        }
    }

    private func stat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title3.monospacedDigit())
        }
    }
}

/// Multi-selection: totals plus the batch actions, which is the whole point of selecting many.
struct SelectionSummaryView: View {
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

            WorkoutActions(ids: Set(items.map(\.id)))
                .buttonStyle(.bordered)

            Spacer()
        }
        .padding(20)
        .navigationTitle("\(items.count) Selected")
    }

    private func stat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title3.monospacedDigit())
        }
    }
}
