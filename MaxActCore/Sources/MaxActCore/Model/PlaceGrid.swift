import Foundation

/// Coarsening a route's start before anything is done with it.
///
/// **This is a privacy boundary, not an optimisation.** A route's first fix is where the athlete
/// left the house, and reverse geocoding it unsnapped returns the street address: measured against
/// a real workout, the raw coordinate resolved to *"4629 Haggart St, Vancouver"*. Snapping happens
/// before the coordinate is **stored** and before it is **sent to the geocoder**, so neither the
/// database nor Apple ever sees the precise point.
///
/// The same snapping doubles as the geocoding cache key: repeat rides from one trailhead land in
/// one cell, so a seven-year corpus costs a request per *place* rather than per workout.
public enum PlaceGrid {
    /// Cell size. Measured displacement over a sampled grid at 49° N: 290–490 m typical, **704 m
    /// worst case** — comfortably sub-kilometre, and far coarser than a building.
    public static let cellMeters: Double = 1000

    /// Metres per degree of latitude. Constant enough for this: the variation from equator to pole
    /// is under 1%, which is nothing against a kilometre-sized cell.
    private static let metersPerDegreeLatitude: Double = 111_320

    /// Snaps to the nearest node of a roughly square grid.
    ///
    /// Longitude spacing is derived from the *snapped* latitude rather than the input, so the
    /// result depends only on which cell the point fell in and two nearby points can't snap to
    /// grids of different widths.
    public static func snap(_ coordinate: Coordinate) -> Coordinate {
        let latitudeStep = cellMeters / metersPerDegreeLatitude
        let latitude = (coordinate.latitude / latitudeStep).rounded() * latitudeStep

        // A degree of longitude shrinks to nothing at the poles; without a floor the step goes to
        // infinity and every point in the Arctic snaps to the prime meridian.
        let scale = max(cos(latitude * .pi / 180), 0.01)
        let longitudeStep = cellMeters / (metersPerDegreeLatitude * scale)
        let longitude = (coordinate.longitude / longitudeStep).rounded() * longitudeStep

        return Coordinate(
            latitude: min(max(latitude, -90), 90),
            longitude: wrapLongitude(longitude)
        )
    }

    /// The first fix of a route, snapped. `nil` for a route with no usable fixes.
    ///
    /// Reads the **cleaned** route, because a spurious first fix would otherwise put the workout
    /// in the wrong city — and the measured artifacts land up to 1,826 m away.
    public static func start(of route: [RoutePoint]) -> Coordinate? {
        RouteQuality.cleaned(route).first.map { snap($0.coordinate) }
    }

    /// A stable string for one cell, for caching resolved names.
    ///
    /// Four decimals is about 11 m at this latitude — far finer than the grid, so distinct cells
    /// can never collide, and the value is already snapped so equal cells always agree.
    public static func cacheKey(for coordinate: Coordinate) -> String {
        String(format: "%.4f,%.4f", coordinate.latitude, coordinate.longitude)
    }

    /// Brings a longitude back into −180...180, which rounding at the antimeridian can leave.
    private static func wrapLongitude(_ longitude: Double) -> Double {
        var wrapped = longitude
        while wrapped > 180 { wrapped -= 360 }
        while wrapped < -180 { wrapped += 360 }
        return wrapped
    }
}
