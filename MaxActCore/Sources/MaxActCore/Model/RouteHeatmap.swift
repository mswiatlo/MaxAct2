import Foundation

/// A square of the map someone has been through — the "explorer tile" of VeloViewer and
/// StatsHunters: a standard web-map tile at zoom 14, about 1.6 km across at Vancouver's latitude.
public struct ExplorerTile: Hashable, Codable, Sendable {
    public static let zoom = 14

    public let x: Int
    public let y: Int

    public init(x: Int, y: Int) {
        self.x = x
        self.y = y
    }

    /// The tile containing `coordinate` (the usual slippy-map formula).
    public init(_ coordinate: Coordinate) {
        let n = Double(1 << Self.zoom)
        let latitude = coordinate.latitude * .pi / 180
        x = Int(((coordinate.longitude + 180) / 360 * n).rounded(.down))
        y = Int(((1 - asinh(tan(latitude)) / .pi) / 2 * n).rounded(.down))
    }

    /// The tile's north-west and south-east corners, for drawing it.
    public var corners: (northWest: Coordinate, southEast: Coordinate) {
        (Self.corner(x, y), Self.corner(x + 1, y + 1))
    }

    private static func corner(_ x: Int, _ y: Int) -> Coordinate {
        let n = Double(1 << zoom)
        let longitude = Double(x) / n * 360 - 180
        let latitude = atan(sinh(.pi * (1 - 2 * Double(y) / n))) * 180 / .pi
        return Coordinate(latitude: latitude, longitude: longitude)
    }
}

/// One workout's route as the heat map needs it: simplified for drawing, plus every explorer tile
/// the *full* route passed through (simplifying first would skip tiles a long straight crosses).
public struct RouteSketch: Codable, Sendable, Equatable {
    public let workoutID: String
    public let coordinates: [Coordinate]
    public let tiles: Set<ExplorerTile>

    public init(workoutID: String, coordinates: [Coordinate], tiles: Set<ExplorerTile>) {
        self.workoutID = workoutID
        self.coordinates = coordinates
        self.tiles = tiles
    }

    /// From a stored series. `nil` for a workout without a usable route (indoor, or GPS discarded).
    ///
    /// Simplified to ~300 points: measured over the user's 418 routes, 926k points became 72k
    /// (1.7 s, debug) — the full set took 7.4 s just to load, which is why sketches are cached.
    public init?(series: WorkoutSeries) {
        let route = series.cleanedRoute.map(\.coordinate)
        guard route.count >= 2 else { return nil }
        self.init(workoutID: series.workoutID,
                  coordinates: RouteSimplifier.simplify(route, fittingPixels: 600, cap: 300),
                  tiles: Set(route.map(ExplorerTile.init)))
    }
}

/// What the statistics need from one workout's stored series, read once and cached
/// (``RouteSketchCache``): its route sketch, if it has a usable route, and its time at each heart
/// rate. Loading the series is the slow part — 7.4 s for 418 — so everything derived from them is
/// taken in the same pass.
public struct SeriesDigest: Codable, Sendable, Equatable {
    public let workoutID: String
    public let sketch: RouteSketch?
    public let heartRate: HeartRateHistogram

    public init(workoutID: String, sketch: RouteSketch?, heartRate: HeartRateHistogram) {
        self.workoutID = workoutID
        self.sketch = sketch
        self.heartRate = heartRate
    }

    public init(series: WorkoutSeries) {
        self.init(workoutID: series.workoutID, sketch: RouteSketch(series: series),
                  heartRate: HeartRateHistogram(series.heartRate))
    }
}

/// A place where workouts happen: the routes that start within ``radius`` of each other, named
/// after the place most of them were labelled with.
public struct RouteRegion: Identifiable, Equatable, Sendable {
    public let name: String
    public let workoutIDs: [String]
    /// Everything in the place.
    public let bounds: CoordinateBounds
    /// Where most of it is: the 2nd–98th percentile of route points on each axis. What the map
    /// frames — measured on the user's home place, the full bounds ran from Vancouver to Seattle
    /// because of one trip to Victoria, and the routes were a speck in a corner.
    public let focus: CoordinateBounds

    /// Its first workout: unique, unlike the name (two places can share one).
    public var id: String { workoutIDs.first ?? name }
    public var count: Int { workoutIDs.count }
}

/// Routes on one map, issue 15.
///
/// **Places, not one map:** measured on the user's library, half of all workouts start within 70 m
/// of home but 10% start more than 1,600 km away (the farthest 9,757 km). A map fitting every route
/// would show a continent and no routes, so routes are grouped by where they start and the map
/// opens on the biggest group.
public enum RouteHeatmap {
    /// How close starts must be to count as one place. Places group by where routes *start*, so a
    /// long ride from home stays with home however far it goes; the radius only has to span a
    /// metro area. 100 km was tried first and merged Vancouver with Victoria (~95 km), framing the
    /// map on the strait between them — the user had real workouts in both.
    public static let radius: Double = 25_000

    /// Groups sketches into places, biggest first. `placeNames` maps workout ids to their place
    /// labels ("Vancouver BC"); a place is named after its most common label, or "Unnamed place".
    ///
    /// Greedy: each route joins the first place whose first route started within ``radius``, else
    /// starts a new one, in the order given — callers pass newest first, so places stay put as the
    /// library grows backwards in time.
    public static func regions(_ sketches: [RouteSketch], placeNames: [String: String]) -> [RouteRegion] {
        var groups: [(anchor: Coordinate, members: [RouteSketch])] = []
        for sketch in sketches {
            guard let start = sketch.coordinates.first else { continue }
            if let index = groups.firstIndex(where: { WorkoutSplits.distance(from: $0.anchor, to: start) <= radius }) {
                groups[index].members.append(sketch)
            } else {
                groups.append((start, [sketch]))
            }
        }
        return groups.compactMap { group in
            guard let bounds = CoordinateBounds(group.members.flatMap(\.coordinates)) else { return nil }
            let names = group.members.compactMap { placeNames[$0.workoutID] }
            let name = Dictionary(grouping: names, by: { $0 }).max { ($0.value.count, $1.key) < ($1.value.count, $0.key) }?.key
            let points = group.members.flatMap(\.coordinates)
            return RouteRegion(name: name ?? "Unnamed place", workoutIDs: group.members.map(\.workoutID),
                               bounds: bounds, focus: focus(of: points) ?? bounds)
        }
        .sorted { ($0.count, $1.name) > ($1.count, $0.name) }
    }

    /// The 2nd–98th percentile box of `points`, so a few outlying routes don't set the framing.
    static func focus(of points: [Coordinate]) -> CoordinateBounds? {
        guard !points.isEmpty else { return nil }
        let latitudes = points.map(\.latitude).sorted(), longitudes = points.map(\.longitude).sorted()
        func at(_ values: [Double], _ fraction: Double) -> Double {
            values[min(values.count - 1, Int(Double(values.count - 1) * fraction))]
        }
        return CoordinateBounds([
            Coordinate(latitude: at(latitudes, 0.02), longitude: at(longitudes, 0.02)),
            Coordinate(latitude: at(latitudes, 0.98), longitude: at(longitudes, 0.98)),
        ])
    }

    /// Every tile any of `sketches` passed through.
    public static func tiles(_ sketches: some Sequence<RouteSketch>) -> Set<ExplorerTile> {
        sketches.reduce(into: Set()) { $0.formUnion($1.tiles) }
    }
}
