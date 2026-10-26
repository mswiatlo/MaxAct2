import MapKit
import MaxActCore
import SwiftUI

extension RouteSketch: @retroactive Identifiable {
    public var id: String { workoutID }
}

/// Every route on one map, with explorer squares (issue 15). Follows the statistics' activity
/// picker and search, like the rest of the page.
///
/// Opens on the place with the most workouts; a menu jumps to the others. One map fitting every
/// route would show a continent — measured, 10% of the user's workouts start over 1,600 km from
/// home — so places are grouped by where routes start (see `RouteHeatmap.regions`).
struct RouteHeatmapSection: View {
    let model: AppModel
    let workouts: [Workout]

    @State private var regionID: String?
    @State private var position: MapCameraPosition = .automatic
    @AppStorage("heatmapShowsSquares") private var showsSquares = false
    /// Several routes under a click: the picker's contents and where it points (issue 29).
    @State private var pick: Pick?

    struct Pick: Identifiable {
        let id = UUID()
        let workoutIDs: [String]
        let anchor: UnitPoint
    }

    static let mapHeight: CGFloat = 380
    /// How near, on screen, a click must be to a route to land on it. In points, so it feels the
    /// same at every zoom; the lines are 2 pt wide.
    static let clickTolerance: CGFloat = 10

    private var routeColor: Color { Color(model.settings.routeColor) }

    var body: some View {
        // Newest first, so places keep their order as older history is added.
        let sketches = workouts.sorted { $0.start > $1.start }.compactMap { model.routeSketches[$0.id] }
        let placeNames = Dictionary(model.items.compactMap { item in item.placeLabel.map { (item.id, $0) } },
                                    uniquingKeysWith: { first, _ in first })
        let regions = RouteHeatmap.regions(sketches, placeNames: placeNames)
        let region = regions.first { $0.id == regionID } ?? regions.first

        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Routes", systemImage: "map")
                    .font(.title3.weight(.semibold))
                Spacer()
                if regions.count > 1, let region {
                    Picker("Place", selection: Binding(get: { region.id }, set: { show($0, in: regions) })) {
                        ForEach(regions) { Text("\($0.name) · \($0.count)").tag($0.id) }
                    }
                    .fixedSize()
                    .accessibilityLabel("Place")
                }
            }

            if let progress = model.routeSketchProgress {
                // The map's own size, so the page doesn't jump when it arrives — it did, and a
                // click aimed below landed on the wrong thing.
                RoundedRectangle(cornerRadius: 8)
                    .fill(.quaternary.opacity(0.5))
                    .frame(height: Self.mapHeight)
                    .overlay {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text(progress.total == 0 ? "Preparing routes…"
                                 : "Preparing routes — \(progress.done) of \(progress.total). Only needed once.")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                    }
            } else if sketches.isEmpty {
                Text("No routes yet — routes come with each workout's detail, from the Sync panel.")
                    .foregroundStyle(.secondary)
            } else {
                map(sketches)
                squaresSummary(all: sketches, region: region)
            }
        }
        .task { await model.loadRouteSketches() }
        // On first appearance, when the routes finish loading, and when the activity picker or the
        // search changes the set: start on its biggest place. `.automatic` would fit everything —
        // the continent this exists to avoid.
        .onChange(of: regions.first?.id, initial: true) {
            regionID = nil
            if let home = regions.first { position = .region(Self.region(for: home)) }
        }
    }

    private func map(_ sketches: [RouteSketch]) -> some View {
        GeometryReader { geometry in
            MapReader { proxy in
                routesMap(sketches)
                    // A click opens the workout under it, or offers a choice where several
                    // overlap (issue 29). Through `reveal`, so Back returns here.
                    .onTapGesture { location in
                        let hits = routes(at: location, among: sketches, proxy: proxy)
                        if hits.count == 1 {
                            model.reveal(hits[0])
                        } else if hits.count > 1 {
                            pick = Pick(workoutIDs: hits, anchor: UnitPoint(
                                x: location.x / max(geometry.size.width, 1),
                                y: location.y / max(geometry.size.height, 1)))
                        }
                    }
                    .popover(item: $pick, attachmentAnchor: .point(pick?.anchor ?? .center)) { pick in
                        RoutePicker(model: model, workoutIDs: pick.workoutIDs) { self.pick = nil }
                    }
            }
        }
        .frame(height: Self.mapHeight)
        .clipShape(.rect(cornerRadius: 8))
        .accessibilityLabel("Map of \(sketches.count) routes")
    }

    /// The routes within ``clickTolerance`` of a click, nearest first.
    private func routes(at location: CGPoint, among sketches: [RouteSketch], proxy: MapProxy) -> [String] {
        guard let clicked = proxy.convert(location, from: .local),
              let aside = proxy.convert(CGPoint(x: location.x + Self.clickTolerance, y: location.y), from: .local)
        else { return [] }
        // The tolerance in metres at this zoom: how far 10 pt reaches on the map here.
        let metres = WorkoutSplits.distance(
            from: Coordinate(latitude: clicked.latitude, longitude: clicked.longitude),
            to: Coordinate(latitude: aside.latitude, longitude: aside.longitude))
        return RouteHeatmap.routes(near: Coordinate(latitude: clicked.latitude, longitude: clicked.longitude),
                                   within: metres, among: sketches)
    }

    private func routesMap(_ sketches: [RouteSketch]) -> some View {
        Map(position: $position) {
            if showsSquares {
                ForEach(Array(RouteHeatmap.tiles(sketches)), id: \.self) { tile in
                    let corners = tile.corners
                    MapPolygon(coordinates: [
                        CLLocationCoordinate2D(latitude: corners.northWest.latitude, longitude: corners.northWest.longitude),
                        CLLocationCoordinate2D(latitude: corners.northWest.latitude, longitude: corners.southEast.longitude),
                        CLLocationCoordinate2D(latitude: corners.southEast.latitude, longitude: corners.southEast.longitude),
                        CLLocationCoordinate2D(latitude: corners.southEast.latitude, longitude: corners.northWest.longitude),
                    ])
                    .foregroundStyle(Color.blue.opacity(0.12))
                    .stroke(Color.blue.opacity(0.45), lineWidth: 0.5)
                }
            }
            // Faint lines, so where routes overlap the colour builds up — that's the heat.
            ForEach(sketches) { sketch in
                MapPolyline(coordinates: sketch.coordinates.map {
                    CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude)
                })
                .stroke(routeColor.opacity(0.35), lineWidth: 2)
            }
        }
        .mapStyle(.standard(emphasis: .muted))
    }

    private func squaresSummary(all sketches: [RouteSketch], region: RouteRegion?) -> some View {
        let total = RouteHeatmap.tiles(sketches).count
        let here = region.map { region in
            RouteHeatmap.tiles(sketches.filter { region.workoutIDs.contains($0.workoutID) }).count
        }
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 32) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Explorer squares").font(.caption).foregroundStyle(.secondary)
                    Text("\(total)").font(.title3.monospacedDigit())
                }
                .accessibilityElement(children: .combine)
                if let here, let region, here != total {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("In \(region.name)").font(.caption).foregroundStyle(.secondary)
                        Text("\(here)").font(.title3.monospacedDigit())
                    }
                    .accessibilityElement(children: .combine)
                }
                Spacer()
                Toggle("Show squares", isOn: $showsSquares)
                    .toggleStyle(.checkbox)
            }
            Text(verbatim: "Squares are map tiles at zoom 14 — about "
                 + Self.tileWidth(at: region).formatted(.number.precision(.fractionLength(1)))
                 + " km across here — that any route has passed through, as counted by VeloViewer and StatsHunters.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func show(_ id: String, in regions: [RouteRegion]) {
        regionID = id
        if let region = regions.first(where: { $0.id == id }) {
            withAnimation { position = .region(Self.region(for: region)) }
        }
    }

    /// A zoom-14 tile's width in km: they narrow away from the equator (1.6 km at Vancouver).
    static func tileWidth(at place: RouteRegion?) -> Double {
        let latitude = place?.bounds.centre.latitude ?? 0
        return 40_075 * cos(latitude * .pi / 180) / Double(1 << ExplorerTile.zoom)
    }

    static func region(for place: RouteRegion) -> MKCoordinateRegion {
        MKCoordinateRegion(fitting: place.focus, headroom: 1.15, minimumSpan: 0.02)
    }
}

/// Where several routes overlap under a click on the heatmap: every one, newest first, to pick
/// from (issue 29). Near home that can be hundreds, so it's a plain scrolling list.
struct RoutePicker: View {
    let model: AppModel
    let workoutIDs: [String]
    let dismiss: () -> Void

    var body: some View {
        let ids = Set(workoutIDs)
        let items = model.items.filter { ids.contains($0.id) }.sorted { $0.workout.start > $1.workout.start }
        VStack(alignment: .leading, spacing: 0) {
            Text("\(items.count) routes pass here")
                .font(.headline)
                .padding([.horizontal, .top], 12)
                .padding(.bottom, 6)
            List(items) { item in
                Button {
                    dismiss()
                    model.reveal(item.id)
                } label: {
                    HStack {
                        Label(item.workout.kind.displayName, systemImage: item.workout.kind.symbolName)
                        Spacer()
                        Text(item.workout.start, format: .dateTime.year().month(.abbreviated).day())
                            .foregroundStyle(.secondary)
                        Text(WorkoutFormatting.distance(item.workout.distanceMeters))
                            .frame(width: 70, alignment: .trailing)
                        Text(WorkoutFormatting.duration(item.workout.duration))
                            .frame(width: 60, alignment: .trailing)
                    }
                    .font(.callout.monospacedDigit())
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
            }
            .listStyle(.plain)
            .accessibilityIdentifier("HeatmapRoutePicker")
        }
        .frame(width: 420, height: min(80 + CGFloat(items.count) * 28, 380))
    }
}
