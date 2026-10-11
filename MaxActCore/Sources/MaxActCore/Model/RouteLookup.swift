import Foundation

/// Finding where a workout was at a given moment, and when it was at a given place — what links
/// the detail pane's charts and map to each other.
///
/// **Timestamp is the shared key, not an array index.** The charts are thinned to
/// ``WorkoutCharts/displayLimit`` marks and the map line is simplified for drawing, so a chart's x
/// value usually falls between drawn points and a clicked spot on the map is rarely a vertex.
/// Every lookup here therefore runs against the full, cleaned route
/// (``WorkoutSeries/cleanedRoute``).
public enum RouteLookup {
    /// How far a time may sit from the nearest fix and still count as "there". Route points are
    /// 1 Hz, so a few seconds covers a dropped sample or two. Beyond it — inside a pause — there is
    /// no honest position to show, and showing the spot the athlete left minutes earlier would be
    /// a claim the data doesn't make.
    public static let timeTolerance: TimeInterval = 5

    /// The fix nearest `date`, if one lies within `tolerance`. `route` must be in time order, as
    /// stored routes are; the search is binary.
    public static func point(
        at date: Date, in route: [RoutePoint], tolerance: TimeInterval = timeTolerance
    ) -> RoutePoint? {
        guard !route.isEmpty else { return nil }
        var low = 0, high = route.count - 1
        while low < high {
            let mid = (low + high) / 2
            if route[mid].timestamp < date { low = mid + 1 } else { high = mid }
        }
        // `low` is the first fix at or after `date`; its predecessor may be closer.
        let candidates = [low - 1, low].filter { route.indices.contains($0) }.map { route[$0] }
        guard let nearest = candidates.min(by: {
            abs($0.timestamp.timeIntervalSince(date)) < abs($1.timestamp.timeIntervalSince(date))
        }), abs(nearest.timestamp.timeIntervalSince(date)) <= tolerance else { return nil }
        return nearest
    }

    /// The fix nearest `coordinate`, with its distance in metres, or `nil` for an empty route.
    ///
    /// Always returns *something* for a non-empty route, so the caller must decide whether the
    /// click was near enough to mean it — and that has to be judged on screen, since a fixed
    /// distance in metres means different things at every zoom level. One linear pass: a few
    /// thousand points per click.
    public static func nearest(
        to coordinate: Coordinate, in route: [RoutePoint]
    ) -> (point: RoutePoint, meters: Double)? {
        var best: (point: RoutePoint, meters: Double)?
        for point in route {
            let meters = WorkoutSplits.distance(from: coordinate, to: point.coordinate)
            if best == nil || meters < best!.meters { best = (point, meters) }
        }
        return best
    }

    /// A chart's value at `date`: the nearest drawn point **within the segment that spans it**,
    /// or `nil` when `date` falls in a pause between segments or outside the chart.
    ///
    /// Snapping within the segment rather than within a fixed time: chart points are thinned, so
    /// on a long ride neighbouring marks can be tens of seconds apart, yet any time inside a
    /// segment genuinely has a value. Across a pause it doesn't.
    public static func value(at date: Date, in segments: [ChartSegment]) -> Double? {
        for segment in segments {
            guard let first = segment.points.first, let last = segment.points.last,
                  first.date <= date, date <= last.date else { continue }
            return segment.points.min {
                abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date))
            }?.value
        }
        return nil
    }
}
