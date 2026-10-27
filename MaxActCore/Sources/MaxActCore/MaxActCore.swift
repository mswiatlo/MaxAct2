/// Shared model, ingest, format and Strava logic for MaxAct.
///
/// This package knows nothing about SwiftUI, so its contents can be exercised with `swift test`
/// without launching the app. It does use SwiftData, for the store (`WorkoutStore`), which runs
/// in memory under test.
public enum MaxActCore {
    /// The date format Health Auto Export uses for every timestamp it emits, in every transport.
    ///
    /// Example: `2024-02-06 07:00:00 -0800`. The offset is always present, so timestamps are
    /// unambiguous and must not be parsed with a fixed time zone.
    public static let haeDateFormat = "yyyy-MM-dd HH:mm:ss Z"
}
