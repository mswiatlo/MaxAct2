import MapKit
import MaxActCore
import SwiftUI

/// The third column: nothing, one workout, or an aggregate of many.
struct DetailPane: View {
    let model: AppModel

    var body: some View {
        content
            // Sized by the widest thing in here, which is a splits row: label, pace, bar, time,
            // heart rate and climb across six columns. At the old 300pt minimum those wrapped and
            // collided; 440 fits a row with room to spare, verified by rendering the table at
            // exactly that width. Capped so a wide inspector can't squeeze the table away.
            .inspectorColumnWidth(min: 440, ideal: 560, max: 760)
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
            WorkoutDetailView(model: model, item: model.selectedItems[0])
        default:
            SelectionSummaryView(model: model, items: model.selectedItems)
        }
    }
}

/// One workout in full: the route, the summary stats, heart rate, pace or speed, elevation, and
/// per-kilometre splits.
///
/// Everything below the stats grid depends on the stored series, so it appears only once detail
/// has been downloaded — under lazy fetching that is an ordinary state, not a failure.
struct WorkoutDetailView: View {
    let model: AppModel
    let item: WorkoutListItem

    /// The loaded series, tagged with the workout it belongs to.
    ///
    /// Tagged rather than stored bare because SwiftUI **reuses this view** across selection
    /// changes — same view type in the same position, so the instance and its `@State` survive.
    /// Carrying the id means a series can never be drawn under the wrong header, not even for
    /// the frame or two before the new one finishes loading.
    @State private var loaded: LoadedSeries?

    /// Bound rather than `Map(initialPosition:)`. An initial position is applied once, when the
    /// map view is created, and because the map is reused the *first* workout's region stuck for
    /// every selection after it.
    @State private var camera: MapCameraPosition = .automatic

    private var workout: Workout { item.workout }

    /// The series plus everything derived from it, computed once per selection instead of on every
    /// body evaluation.
    private struct LoadedSeries {
        let id: String
        let series: WorkoutSeries
        let coordinates: [CLLocationCoordinate2D]
        /// Spurious fixes dropped from the drawn track. Reported rather than hidden — the map is
        /// then demonstrably not the raw recording.
        let discardedFixes: Int
        let movingSpeedMetersPerSecond: Double?
        let splits: [Split]
        let heartRate: [ChartSegment]
        let elevation: [ChartSegment]
        let speed: [ChartSegment]
        let pace: [ChartSegment]
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header

                // Only ever trust the loaded series when it belongs to the workout on screen.
                let series = loaded.flatMap { $0.id == item.id ? $0 : nil }

                if let series, !series.coordinates.isEmpty {
                    routeMap(series.coordinates)
                } else if workout.hasRoute && !item.hasDetail {
                    notDownloadedNotice
                }

                statsGrid(series)

                if let series {
                    charts(series)
                    SplitsTable(
                        splits: series.splits,
                        kind: workout.kind,
                        tint: Color(model.settings.routeColor)
                    )
                }
            }
            .padding(20)
        }
        .navigationTitle(workout.kind.displayName)
        .task(id: item.id) { await load() }
    }

    private func load() async {
        // Cleared before the await, not after: otherwise the previous workout's route stays on
        // screen underneath the new workout's header until the load finishes.
        loaded = nil
        camera = .automatic

        guard let series = await model.seriesStore.loadIfAvailable(item.id) else { return }

        // Cleaned before anything else looks at it: one bad fix draws a kilometres-long spike
        // across the map, and the stored blob keeps the raw recording either way.
        let route = series.cleanedRoute
        // Simplified for display too: drawing 12,645 points into a few hundred on-screen pixels
        // costs a great deal and shows nothing extra.
        let simplified = RouteSimplifier.simplify(route.map(\.coordinate), fittingPixels: 900)
        loaded = LoadedSeries(
            id: item.id,
            series: series,
            coordinates: simplified.map {
                CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude)
            },
            discardedFixes: series.route.count - route.count,
            movingSpeedMetersPerSecond: workout.movingSpeedMetersPerSecond(using: series),
            // Splits and chart series are derived once here rather than in `body`. Each walks
            // thousands of points, and body runs on every hover, resize and scroll.
            splits: WorkoutSplits.splits(for: workout, series: series),
            heartRate: WorkoutCharts.heartRate(series),
            elevation: WorkoutCharts.elevation(series),
            speed: WorkoutCharts.speed(series),
            pace: WorkoutCharts.pace(series, for: workout.kind)
        )

        // 30% headroom so the track isn't flush against the edges. Set last, once the route is
        // actually in hand — the map exists well before the series arrives.
        if let region = MKCoordinateRegion(fitting: simplified, headroom: 1.3, minimumSpan: 0.003) {
            camera = .region(region)
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

    private func routeMap(_ coordinates: [CLLocationCoordinate2D]) -> some View {
        Map(position: $camera) {
            MapPolyline(coordinates: coordinates)
                .stroke(
                    Color(model.settings.routeColor),
                    style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round)
                )
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

    /// The three charts the plan calls for, in the order they answer questions: how hard, how
    /// fast, how hilly.
    @ViewBuilder
    private func charts(_ series: LoadedSeries) -> some View {
        let tint = Color(model.settings.routeColor)

        SeriesChart(
            title: "Heart Rate",
            systemImage: "heart",
            segments: series.heartRate,
            tint: .pink,
            format: { "\(Int($0.rounded()))" }
        )

        // Two different series, not one relabelled: pace is seconds per kilometre on a reversed
        // axis so faster reads as higher, while speed is metres per second the usual way up.
        if workout.kind.isPaceBased {
            SeriesChart(
                title: "Pace",
                systemImage: "speedometer",
                segments: series.pace,
                tint: tint,
                format: { WorkoutFormatting.paceLabel(secondsPerKilometer: $0) },
                reversed: true
            )
        } else {
            SeriesChart(
                title: "Speed",
                systemImage: "speedometer",
                segments: series.speed,
                tint: tint,
                format: { WorkoutFormatting.speed(metersPerSecond: $0) }
            )
        }

        SeriesChart(
            title: "Elevation",
            systemImage: "mountain.2",
            segments: series.elevation,
            tint: .teal,
            format: { "\(Int($0.rounded())) m" }
        )
    }

    private func statsGrid(_ series: LoadedSeries?) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Grid(alignment: .leading, horizontalSpacing: 28, verticalSpacing: 10) {
                GridRow {
                    stat("Duration", WorkoutFormatting.duration(workout.duration))
                    stat("Distance", WorkoutFormatting.distance(workout.distanceMeters))
                    stat("Energy", WorkoutFormatting.energy(kilocalories: workout.activeEnergyKilocalories))
                }
                GridRow {
                    // "Elapsed" rather than "Avg", now that a moving figure sits beside it —
                    // labelling one of two averages simply "Avg" invites reading the wrong one.
                    stat("Elapsed Pace", WorkoutFormatting.paceOrSpeed(
                        metersPerSecond: workout.effectiveSpeedMetersPerSecond, for: workout.kind))
                    if let moving = series?.movingSpeedMetersPerSecond {
                        stat("Moving Pace", WorkoutFormatting.paceOrSpeed(
                            metersPerSecond: moving, for: workout.kind))
                    }
                    stat("Avg HR", WorkoutFormatting.heartRate(workout.averageHeartRate))
                    stat("Max HR", WorkoutFormatting.heartRate(workout.maximumHeartRate))
                }
                GridRow {
                    stat("Ascent", WorkoutFormatting.elevation(meters: workout.elevationAscendedMeters))
                    stat("Descent", WorkoutFormatting.elevation(meters: workout.elevationDescendedMeters))
                    if let series {
                        stat(
                            "Samples",
                            "\(series.series.route.count) pts · \(series.series.heartRate.count) HR"
                        )
                    }
                }
            }

            if let discarded = series?.discardedFixes, discarded > 0 {
                Label(
                    "\(discarded) GPS \(discarded == 1 ? "fix" : "fixes") left out of the map as "
                        + "implausible. The recording itself is unchanged.",
                    systemImage: "antenna.radiowaves.left.and.right.slash"
                )
                .font(.callout)
                .foregroundStyle(.secondary)
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
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title3.monospacedDigit())
        }
    }
}
