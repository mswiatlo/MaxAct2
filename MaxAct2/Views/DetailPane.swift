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
            //
            // **Opens at its minimum.** With an ideal of 560 it opened at 560 even when that
            // didn't fit: SwiftUI doesn't shrink an opening inspector toward its minimum, it lays
            // the content out wider than the window and centres it — measured, 1,318pt in a
            // 1,300pt window, clipping 9pt off each edge and erasing the sidebar's inset. Dragging
            // it wider still works up to the maximum.
            .inspectorColumnWidth(min: 440, ideal: 440, max: 760)
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

    /// The moment linked across the charts and the map — set by pointing at a chart or clicking
    /// the route, shown by a rule in every chart and a marker on the map. A time rather than an
    /// index, because the charts, the drawn line and the route all have different points.
    @State private var highlighted: Date?

    /// Other times this route was done (issue 23), tagged with its workout like `loaded`.
    @State private var routeHistory: (id: String, history: RouteHistory)?

    /// The route coloured by elevation, heart rate or pace (issue 31), worked out off the main
    /// actor and kept, since the map redraws on every hover. Tagged like `loaded`.
    @State private var coloredRoute: ColoredRoute?

    private struct ColoredRoute {
        let identity: ColoringIdentity
        let runs: [(coordinates: [CLLocationCoordinate2D], color: Color)]
        /// `nil` when shaded by zone; the whole value `nil` when there was nothing to colour by.
        let gradient: RouteGradient?
    }

    /// What the colouring depends on: the workout, the choice, and — for zones — the profile.
    private struct ColoringIdentity: Hashable {
        let workoutID: String?
        let coloring: RouteColoring
        let resting: Double?
        let maximum: Double?
    }

    private var coloringIdentity: ColoringIdentity {
        let profile = item.routeColoring == .heartRate ? model.settings.heartRateProfile : nil
        return ColoringIdentity(workoutID: loaded?.id, coloring: item.routeColoring,
                                resting: profile?.resting, maximum: profile?.maximum)
    }

    /// How close, on screen, a click must land to the route to count as a click *on* it. Judged
    /// in points because a fixed distance in metres means something different at every zoom.
    private static let routeClickTolerance: CGFloat = 20

    private var workout: Workout { item.workout }

    /// The series plus everything derived from it, computed once per selection instead of on every
    /// body evaluation.
    private struct LoadedSeries {
        let id: String
        let series: WorkoutSeries
        /// The full cleaned route, for linking: never the simplified drawing below.
        let route: [RoutePoint]
        let coordinates: [CLLocationCoordinate2D]
        /// Spurious fixes dropped from the drawn track. Reported rather than hidden — the map is
        /// then demonstrably not the raw recording.
        let discardedFixes: Int
        let movingSpeedMetersPerSecond: Double?
        /// Ascent and descent from the route, where the summary has none (issue 20).
        let estimatedAscent: Double?
        let estimatedDescent: Double?
        let splits: [Split]
        let heartRate: [ChartSegment]
        /// Time at each heart rate, for the zones — kept rather than the zone times, so a change
        /// to the profile in Settings shows at once.
        let heartRateHistogram: HeartRateHistogram
        let elevation: [ChartSegment]
        let speed: [ChartSegment]
        let pace: [ChartSegment]
        /// One time axis for all of the charts above, so they align.
        let timeDomain: ClosedRange<Date>
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header

                // Only ever trust the loaded series when it belongs to the workout on screen.
                let series = loaded.flatMap { $0.id == item.id ? $0 : nil }

                if let series, !series.coordinates.isEmpty {
                    routeMap(series)
                    coloringLegend
                    if series.series.routeIsIncomplete(duration: workout.duration) {
                        incompleteRouteNote(series.series)
                    }
                    if let fill = series.series.provenance.routeFromStrava {
                        repairNote("Route from Strava — Health Auto Export sent only "
                                   + Self.span(fill.exportedSeconds) + " of " + Self.span(workout.duration) + ".")
                    }
                } else if workout.hasRoute && !item.hasDetail {
                    notDownloadedNotice
                }

                statsGrid(series)

                if let series {
                    if let fill = series.series.provenance.heartRateFromMetrics {
                        repairNote("Heart rate from Health's samples — Health Auto Export's workout export had "
                                   + "\(fill.exportedReadings) \(fill.exportedReadings == 1 ? "reading" : "readings").")
                    }
                    charts(series)
                    // Below the last chart, Elevation: this workout first, other times after.
                    if let routeHistory, routeHistory.id == item.id {
                        RouteHistoryView(history: routeHistory.history, kind: workout.kind,
                                         tint: Color(model.settings.routeColor),
                                         open: { model.reveal($0) })
                    } else if let progress = model.routeSketchProgress, workout.hasRoute, item.hasDetail {
                        // The first time, every route is read; without this the section's absence
                        // would look like "never done before" until it finishes.
                        Label(progress.total > 0
                              ? "Looking for other times on this route… \(progress.done) of \(progress.total)"
                              : "Looking for other times on this route…",
                              systemImage: "hourglass")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("RouteHistoryProgress")
                    }
                    if series.heartRateHistogram.total > 0 {
                        zones(series.heartRateHistogram)
                    }
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
        .task(id: coloringIdentity) { await colorRoute(coloringIdentity) }
        // Separate from `load`, so the route and charts don't wait on matching. Re-run when the
        // sketches arrive, in case they were still being built when this workout was selected.
        .task(id: "\(item.id)-\(model.preparedRoutes.count)") {
            if routeHistory?.id != item.id { routeHistory = nil }
            guard let history = await model.routeHistory(for: item) else {
                routeHistory = nil
                return
            }
            routeHistory = (item.id, history)
        }
    }

    private func load() async {
        // Cleared before the await, not after: otherwise the previous workout's route stays on
        // screen underneath the new workout's header until the load finishes.
        loaded = nil
        camera = .automatic
        highlighted = nil

        guard let series = await model.seriesStore.loadIfAvailable(item.id) else { return }

        // Cleaned before anything else looks at it: one bad fix draws a kilometres-long spike
        // across the map, and the stored blob keeps the raw recording either way.
        let route = series.cleanedRoute
        // Simplified for display too: drawing 12,645 points into a few hundred on-screen pixels
        // costs a great deal and shows nothing extra.
        let simplified = RouteSimplifier.simplify(route.map(\.coordinate), fittingPixels: 900)
        let heartRate = WorkoutCharts.heartRate(series)
        let elevation = WorkoutCharts.elevation(series)
        let speed = WorkoutCharts.speed(series)
        let pace = WorkoutCharts.pace(series, for: workout.kind)
        loaded = LoadedSeries(
            id: item.id,
            series: series,
            route: route,
            coordinates: simplified.map {
                CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude)
            },
            discardedFixes: series.route.count - route.count,
            movingSpeedMetersPerSecond: workout.movingSpeedMetersPerSecond(using: series),
            estimatedAscent: workout.elevationAscendedMeters == nil ? ElevationEstimate.ascent(route: route) : nil,
            estimatedDescent: workout.elevationDescendedMeters == nil
                ? ElevationEstimate.descent(reportedAscent: workout.elevationAscendedMeters, route: route) : nil,
            // Splits and chart series are derived once here rather than in `body`. Each walks
            // thousands of points, and body runs on every hover, resize and scroll.
            splits: WorkoutSplits.splits(for: workout, series: series),
            heartRate: heartRate,
            heartRateHistogram: HeartRateHistogram(series.heartRate),
            elevation: elevation,
            speed: speed,
            pace: pace,
            timeDomain: WorkoutCharts.timeDomain(
                for: workout, charts: [heartRate, elevation, workout.kind.isPaceBased ? pace : speed])
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

            TagChips(tags: item.tags, pendingOnStrava: item.stravaFlagsPending)

            // The activity itself, once Strava has one — a duplicate links to the existing copy.
            if let activityID = item.stravaActivityID,
               let url = URL(string: "https://www.strava.com/activities/\(activityID)") {
                Link(destination: url) {
                    Label("Open on Strava", systemImage: "arrow.up.right.square")
                }
                .font(.callout)
            }
            // Found rather than uploaded: say how it got there, so "synced" with no upload from
            // MaxAct doesn't look like something went missing.
            if item.stravaState == .duplicate {
                Text("Uploaded to Strava by another source.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            // Failures are never swallowed: Strava's own reason, in words, where the user looks.
            if let reason = item.stravaState.failureReason {
                Label(reason, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .textSelection(.enabled)
            }
        }
    }

    private func routeMap(_ series: LoadedSeries) -> some View {
        // Where the highlighted moment was. Nothing during a pause: there is no honest position.
        let marker = highlighted.flatMap { RouteLookup.point(at: $0, in: series.route) }
        return MapReader { proxy in
            Map(position: $camera) {
                if let colored = coloredRoute, colored.identity == coloringIdentity, colored.gradient != nil {
                    ForEach(colored.runs.indices, id: \.self) { index in
                        MapPolyline(coordinates: colored.runs[index].coordinates)
                            .stroke(colored.runs[index].color,
                                    style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
                    }
                } else {
                    MapPolyline(coordinates: series.coordinates)
                        .stroke(
                            Color(model.settings.routeColor),
                            style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round)
                        )
                }
                if let marker {
                    Annotation(
                        "Highlighted position",
                        coordinate: CLLocationCoordinate2D(
                            latitude: marker.coordinate.latitude, longitude: marker.coordinate.longitude),
                        anchor: .center
                    ) {
                        Circle()
                            .fill(.white)
                            .stroke(Color(model.settings.routeColor), lineWidth: 3)
                            .frame(width: 14, height: 14)
                            .shadow(radius: 1)
                            .accessibilityIdentifier("RouteHighlight")
                    }
                    .annotationTitles(.hidden)
                }
            }
            .onTapGesture { location in
                highlighted = moment(clickedAt: location, on: series.route, proxy: proxy)
            }
        }
        .frame(height: 280)
        .clipShape(.rect(cornerRadius: 10))
        .accessibilityLabel("Route map with \(series.coordinates.count) points")
        .overlay(alignment: .topTrailing) { coloringMenu.padding(8) }
    }

    /// Solid / Elevation / Heart Rate / Pace, on the map itself (issue 31). Each workout keeps
    /// its own choice, so changing it redraws only that workout's thumbnail.
    private var coloringMenu: some View {
        Menu {
            Picker("Colour route by", selection: Binding(
                get: { item.routeColoring }, set: { model.setRouteColoring($0, for: item.id) })) {
                ForEach(RouteColoring.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.inline)
        } label: {
            // The current choice, Solid included — one name, not "Colour" for Solid (user's choice).
            Label(item.routeColoring.title, systemImage: "paintpalette")
        }
        .menuStyle(.button)
        .buttonStyle(.glass)
        .fixedSize()
        .help("Colour the route by elevation, heart rate or pace")
        .accessibilityIdentifier("RouteColoringMenu")
    }

    /// Under the map: what the colours mean — the low and high ends of the ramp, or the zones.
    @ViewBuilder
    private var coloringLegend: some View {
        let coloring = item.routeColoring
        if coloring != .solid, let colored = coloredRoute, colored.identity == coloringIdentity {
            Group {
                if let gradient = colored.gradient, let range = gradient.range {
                    HStack(spacing: 8) {
                        Text(legendValue(range.low, coloring))
                        Capsule()
                            .fill(LinearGradient(colors: RouteShade.ramp, startPoint: .leading, endPoint: .trailing))
                            .frame(height: 6)
                        Text(legendValue(range.high, coloring))
                    }
                } else if colored.gradient != nil {
                    HStack(spacing: 10) {
                        ForEach(HeartRateZone.allCases.filter { $0 != .below }) { zone in
                            HStack(spacing: 4) {
                                Circle().fill(zone.color).frame(width: 8, height: 8)
                                Text(zone.title)
                            }
                        }
                    }
                } else {
                    Text(coloring == .heartRate ? "No heart rate to colour by." : "Nothing to colour by.")
                }
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("RouteColoringLegend")
        }
    }

    private func legendValue(_ value: Double, _ coloring: RouteColoring) -> String {
        switch coloring {
        case .elevation: WorkoutFormatting.elevation(meters: value)
        case .gradient: value.formatted(.number.precision(.fractionLength(0)).sign(strategy: .always(includingZero: false))) + "%"
        case .pace: WorkoutFormatting.paceOrSpeed(metersPerSecond: value, for: workout.kind)
        case .heartRate: WorkoutFormatting.heartRate(value)
        case .solid: ""
        }
    }

    /// Works out the coloured route off the main actor, simplified like the solid line.
    private func colorRoute(_ identity: ColoringIdentity) async {
        guard identity.coloring != .solid, let loaded, loaded.id == identity.workoutID else {
            coloredRoute = nil
            return
        }
        let route = loaded.route, heartRate = loaded.series.heartRate
        let profile = identity.coloring == .heartRate ? model.settings.heartRateProfile : nil
        let result = await Task.detached(priority: .userInitiated) { () -> (RouteGradient, [RouteGradient.Run])? in
            guard let gradient = RouteGradient(identity.coloring, route: route, heartRate: heartRate, profile: profile)
            else { return nil }
            return (gradient, gradient.simplified(fittingPixels: 900))
        }.value
        guard !Task.isCancelled else { return }
        coloredRoute = ColoredRoute(
            identity: identity,
            runs: (result?.1 ?? []).map { run in
                (run.coordinates.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) },
                 run.shade.color)
            },
            gradient: result?.0)
    }

    /// The moment the route passed closest to a click, or `nil` if the click wasn't near the route.
    ///
    /// Nearest-by-coordinate always finds *something*, so the answer is then checked on screen:
    /// a click in empty map clears the highlight rather than jumping to the far side of the ride.
    private func moment(clickedAt location: CGPoint, on route: [RoutePoint], proxy: MapProxy) -> Date? {
        guard let clicked = proxy.convert(location, from: .local),
              let nearest = RouteLookup.nearest(
                  to: Coordinate(latitude: clicked.latitude, longitude: clicked.longitude), in: route),
              let onScreen = proxy.convert(
                  CLLocationCoordinate2D(latitude: nearest.point.coordinate.latitude,
                                         longitude: nearest.point.coordinate.longitude),
                  to: .local)
        else { return nil }
        let distance = hypot(onScreen.x - location.x, onScreen.y - location.y)
        return distance <= Self.routeClickTolerance ? nearest.point.timestamp : nil
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
            format: { "\(Int($0.rounded()))" },
            highlighted: $highlighted,
            timeDomain: series.timeDomain
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
                reversed: true,
                highlighted: $highlighted,
                timeDomain: series.timeDomain
            )
        } else {
            SeriesChart(
                title: "Speed",
                systemImage: "speedometer",
                segments: series.speed,
                tint: tint,
                // Zero is a real speed on this axis — stopped — not a missing value, so it reads
                // "0.0 km/h" rather than the formatter's "—".
                format: { $0 > 0 ? WorkoutFormatting.speed(metersPerSecond: $0) : "0.0 km/h" },
                highlighted: $highlighted,
                timeDomain: series.timeDomain
            )
        }

        SeriesChart(
            title: "Elevation",
            systemImage: "mountain.2",
            segments: series.elevation,
            tint: .teal,
            format: { "\(Int($0.rounded())) m" },
            highlighted: $highlighted,
            timeDomain: series.timeDomain
        )
    }

    /// Data MaxAct filled in around Health Auto Export's export bugs (issue 22) — shown so it's
    /// clear what isn't the export's, and which workouts to re-download once it's fixed.
    private func repairNote(_ text: String) -> some View {
        Label {
            Text(verbatim: text)
        } icon: {
            Image(systemName: "bandage")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .help("Re-download this workout once Health Auto Export fixes its export.")
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("RepairNote")
    }

    /// "27 secs.", "42 mins", "1 hr, 30 mins".
    private static func span(_ seconds: TimeInterval) -> String {
        Duration.seconds(seconds.rounded())
            .formatted(.units(allowed: [.hours, .minutes, .seconds], width: .abbreviated, maximumUnitCount: 2))
    }

    /// Health Auto Export sent only part of this route (issue 19). Linked workouts are filled from
    /// Strava automatically, so this shows for the rest — or if that failed.
    private func incompleteRouteNote(_ series: WorkoutSeries) -> some View {
        let sent = Duration.seconds(series.routeSpan.rounded())
            .formatted(.units(allowed: [.hours, .minutes, .seconds], width: .abbreviated, maximumUnitCount: 2))
        let whole = Duration.seconds(workout.duration.rounded())
            .formatted(.units(allowed: [.hours, .minutes], width: .abbreviated))
        return Label {
            Text(verbatim: "Route incomplete — Health Auto Export sent \(sent) of \(whole)."
                 + (item.stravaActivityID == nil ? "" : " The Strava activity has all of it; MaxAct fills it in while Strava is connected."))
        } icon: {
            Image(systemName: "exclamationmark.triangle")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("IncompleteRouteNote")
    }

    /// The same breakdown as the statistics' Heart-Rate Zones, for this one workout.
    @ViewBuilder
    private func zones(_ histogram: HeartRateHistogram) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Heart-Rate Zones", systemImage: "heart.text.square")
                .font(.headline)
            if let profile = model.settings.heartRateProfile {
                HeartRateZoneBreakdown(times: HeartRateZone.times(histogram, profile: profile), profile: profile)
                // Recording time, which can exceed the workout's duration: that leaves out pauses,
                // while stops under the gap limit still have readings (measured: a 28:14 ride had
                // 32 min of readings over its 32 min recording).
                Text(verbatim: HeartRateZoneBreakdown.describe(histogram.total)
                     + " of readings, over the whole recording. Gaps over \(Int(HeartRateHistogram.maxGap)) s count nothing.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Set your resting and maximum heart rate in Settings to see zones.")
                    .foregroundStyle(.secondary)
            }
        }
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
                    elevationStat("Ascent", reported: workout.elevationAscendedMeters, estimated: series?.estimatedAscent,
                                  how: "summed from the route's heights")
                    elevationStat("Descent", reported: workout.elevationDescendedMeters, estimated: series?.estimatedDescent,
                                  how: workout.elevationAscendedMeters == nil
                                      ? "summed from the route's heights"
                                      : "the recorded ascent plus the height lost from start to finish")
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

    /// Health's figure when it has one; otherwise an estimate, marked "≈" and explained — Health
    /// has no descent for any Apple Workout-app recording (issue 20).
    @ViewBuilder
    private func elevationStat(_ label: String, reported: Double?, estimated: Double?, how: String) -> some View {
        if reported == nil, let estimated {
            stat(label, "≈ " + WorkoutFormatting.elevation(meters: estimated))
                .help("Estimated: Health didn't record this, so it's \(how).")
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(label), about \(WorkoutFormatting.elevation(meters: estimated)), estimated")
                .accessibilityIdentifier("Estimated\(label)")
        } else {
            stat(label, WorkoutFormatting.elevation(meters: reported))
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
