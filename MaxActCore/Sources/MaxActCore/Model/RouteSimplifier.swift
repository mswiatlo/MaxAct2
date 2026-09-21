import Foundation

/// A latitude/longitude bounding box.
public struct CoordinateBounds: Hashable, Sendable {
    public let minLatitude: Double
    public let maxLatitude: Double
    public let minLongitude: Double
    public let maxLongitude: Double

    public var centre: Coordinate {
        Coordinate(
            latitude: (minLatitude + maxLatitude) / 2,
            longitude: (minLongitude + maxLongitude) / 2
        )
    }

    public var latitudeSpan: Double { maxLatitude - minLatitude }
    public var longitudeSpan: Double { maxLongitude - minLongitude }

    /// The span a map should use to show this route: the bounding box plus headroom, never
    /// narrower than `minimumSpan`.
    ///
    /// The floor is the part that matters. A treadmill or a pool workout has a bounding box of a
    /// few metres, and without it the map zooms all the way in and renders a meaningless
    /// close-up of one building. Degrees rather than metres because this feeds
    /// `MKCoordinateSpan`, and callers pass their own values — a 96×56 thumbnail and a 280pt map
    /// don't want the same framing.
    public func displaySpan(
        headroom: Double, minimumSpan: Double
    ) -> (latitude: Double, longitude: Double) {
        (max(latitudeSpan * headroom, minimumSpan), max(longitudeSpan * headroom, minimumSpan))
    }

    public init?(_ coordinates: [Coordinate]) {
        guard let first = coordinates.first else { return nil }
        var minLat = first.latitude, maxLat = first.latitude
        var minLon = first.longitude, maxLon = first.longitude
        for point in coordinates.dropFirst() {
            minLat = min(minLat, point.latitude); maxLat = max(maxLat, point.latitude)
            minLon = min(minLon, point.longitude); maxLon = max(maxLon, point.longitude)
        }
        minLatitude = minLat; maxLatitude = maxLat
        minLongitude = minLon; maxLongitude = maxLon
    }
}

/// Reduces a route to the fewest points that still look like the same shape.
///
/// This is what makes the list affordable. A 3.5-hour hike is 12,645 points at 1 Hz; drawing that
/// into a 120×80 thumbnail wastes almost all of it, since hundreds of points land on the same
/// pixel. Simplifying to a couple of hundred is visually identical at that size and two orders of
/// magnitude less work, per row, on every redraw.
public enum RouteSimplifier {
    /// Ramer–Douglas–Peucker. Keeps the endpoints and any point far enough from the line between
    /// its retained neighbours; drops the rest.
    ///
    /// Distances are computed in a flat local projection with longitude scaled by
    /// `cos(latitude)`. Correct great-circle distance is pointless here — the tolerance is chosen
    /// to be sub-pixel, and the error over a workout-sized area is far below that.
    ///
    /// - Parameter tolerance: in degrees of latitude. The default, ~1.1 m, is well under a pixel
    ///   for any thumbnail and still removes the vast bulk of a 1 Hz track.
    public static func simplify(_ coordinates: [Coordinate], tolerance: Double = 0.00001) -> [Coordinate] {
        guard coordinates.count > 2, tolerance > 0 else { return coordinates }

        let scale = cos(coordinates[0].latitude * .pi / 180)
        var keep = [Bool](repeating: false, count: coordinates.count)
        keep[0] = true
        keep[coordinates.count - 1] = true

        // Explicit stack rather than recursion: a 12,645-point route would otherwise risk
        // a deep call chain on a pathological input.
        var stack: [(Int, Int)] = [(0, coordinates.count - 1)]
        while let (first, last) = stack.popLast() {
            guard last > first + 1 else { continue }

            let start = coordinates[first], end = coordinates[last]
            let dx = (end.longitude - start.longitude) * scale
            let dy = end.latitude - start.latitude
            let lengthSquared = dx * dx + dy * dy

            var farthest = first
            var farthestDistance = 0.0
            for index in (first + 1)..<last {
                let point = coordinates[index]
                let px = (point.longitude - start.longitude) * scale
                let py = point.latitude - start.latitude

                let distance: Double
                if lengthSquared == 0 {
                    distance = (px * px + py * py).squareRoot()
                } else {
                    // Perpendicular distance to the segment, clamped to the segment's extent so a
                    // point beyond an endpoint measures to that endpoint.
                    let t = max(0, min(1, (px * dx + py * dy) / lengthSquared))
                    let ex = px - t * dx, ey = py - t * dy
                    distance = (ex * ex + ey * ey).squareRoot()
                }
                if distance > farthestDistance {
                    farthest = index
                    farthestDistance = distance
                }
            }

            if farthestDistance > tolerance {
                keep[farthest] = true
                stack.append((first, farthest))
                stack.append((farthest, last))
            }
        }

        return zip(coordinates, keep).compactMap { $1 ? $0 : nil }
    }

    /// Simplifies for drawing into a box `pixels` across, choosing the tolerance directly rather
    /// than searching for it.
    ///
    /// The tolerance that matters is "half a pixel": anything finer cannot be seen. Deriving it
    /// from the route's own bounding box is one RDP pass, where bisecting towards a target point
    /// count took nine — 259 ms against 5 ms for the worst real route, which over a full corpus is
    /// the difference between twelve minutes of thumbnail work and fifteen seconds.
    ///
    /// - Parameter cap: a hard ceiling applied afterwards by uniform decimation, so a pathological
    ///   route (dense switchbacks, GPS noise) still cannot make one row expensive.
    public static func simplify(
        _ coordinates: [Coordinate],
        fittingPixels pixels: Int,
        cap: Int = 400
    ) -> [Coordinate] {
        guard coordinates.count > 2, pixels > 0, let bounds = CoordinateBounds(coordinates) else {
            return coordinates
        }
        let scale = cos(bounds.centre.latitude * .pi / 180)
        let span = max(bounds.latitudeSpan, bounds.longitudeSpan * scale)
        guard span > 0 else { return [coordinates[0], coordinates[coordinates.count - 1]] }

        // RDP is O(n²) in the worst case, and a 1 Hz track hits it: one pass over the full
        // 12,645-point hike measured 42 ms. Decimating first bounds that term. Sixteen samples
        // per pixel is far more than can be distinguished, so nothing visible is lost, and the
        // subsequent RDP still chooses *which* points to keep by shape rather than by index.
        let working = decimate(coordinates, to: max(cap * 4, pixels * 16))
        let simplified = simplify(working, tolerance: span / Double(pixels) / 2)
        return decimate(simplified, to: cap)
    }

    /// Uniform sampling that always keeps the first and last point.
    static func decimate(_ coordinates: [Coordinate], to limit: Int) -> [Coordinate] {
        guard coordinates.count > limit, limit > 2 else { return coordinates }
        let stride = Double(coordinates.count - 1) / Double(limit - 1)
        var sampled = (0..<(limit - 1)).map { coordinates[Int(Double($0) * stride)] }
        sampled.append(coordinates[coordinates.count - 1])
        return sampled
    }
}
