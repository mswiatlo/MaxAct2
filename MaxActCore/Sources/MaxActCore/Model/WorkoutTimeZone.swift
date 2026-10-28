import Foundation

/// The time zone a workout happened in, for naming it by its local time ("Morning Run").
///
/// Not HAE's UTC offset: that is the **phone's** zone applied to the date, whatever the workout's
/// location (measured 2026-10-28 — a 07:02 run in Switzerland came back as `22:01:58 -0700`, the
/// evening before). So the zone comes from where the workout started, resolved with its place.
public enum WorkoutTimeZone {
    /// How far an indoor workout may borrow a zone from an outdoor one: a day either side covers a
    /// hotel gym between two runs, without reaching back across a flight home.
    public static let borrowingWindow: TimeInterval = 24 * 3600

    /// The workout's own zone if it has one; for one without (indoor, or not yet resolved), the zone
    /// of the nearest workout that has one within ``borrowingWindow``; else `nil`, for the caller's
    /// default.
    ///
    /// - Parameter others: starts and zone identifiers of other workouts; order doesn't matter.
    public static func zone(start: Date, own: String?, others: [(start: Date, zone: String)]) -> TimeZone? {
        if let own, let zone = TimeZone(identifier: own) { return zone }
        let nearest = others
            .filter { abs($0.start.timeIntervalSince(start)) <= borrowingWindow }
            .min { abs($0.start.timeIntervalSince(start)) < abs($1.start.timeIntervalSince(start)) }
        return nearest.flatMap { TimeZone(identifier: $0.zone) }
    }
}
