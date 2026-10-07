import Foundation

/// One activity from `GET /athlete/activities` — Strava's `SummaryActivity`, cut down to what
/// matching needs.
public struct StravaActivitySummary: Decodable, Sendable, Equatable {
    public let id: Int
    public let name: String?
    public let sportType: String?
    public let startDate: Date
    /// Seconds, including pauses — the right figure to compare with a workout's `start…end`.
    public let elapsedTime: TimeInterval
    public let distance: Double?
    /// What the uploader set. Ours for anything MaxAct uploaded; usually nil or a device's own
    /// value for anything that arrived from the watch or another app.
    public let externalID: String?

    enum CodingKeys: String, CodingKey {
        case id, name, distance
        case sportType = "sport_type"
        case startDate = "start_date"
        case elapsedTime = "elapsed_time"
        case externalID = "external_id"
    }

    public init(id: Int, name: String? = nil, sportType: String? = nil, startDate: Date,
                elapsedTime: TimeInterval, distance: Double? = nil, externalID: String? = nil) {
        self.id = id
        self.name = name
        self.sportType = sportType
        self.startDate = startDate
        self.elapsedTime = elapsedTime
        self.distance = distance
        self.externalID = externalID
    }

    var end: Date { startDate.addingTimeInterval(elapsedTime) }
}

/// Decides which workouts are already on Strava.
///
/// Most of what's there arrived **without MaxAct** — straight from the watch, the Strava app, or
/// WorkOutDoors — so the `external_id` we set on our own uploads usually won't be present. Matching
/// is therefore by *when* the workout happened, with the id used when it does exist.
///
/// The rule, and why each part is there:
/// - **Same `external_id` as the HealthKit UUID** → certain. That's one of ours.
/// - Otherwise **starts within 10 minutes** of each other — different recorders start the clock
///   at slightly different moments (a watch app vs. the phone's) — **and the two intervals overlap
///   for at least half of the shorter one.** Start time alone would pair a 5-minute walk to the
///   bike with the 2-hour ride that followed it; overlap is what makes them the same event.
/// - **One-to-one, best overlap first.** Each Strava activity is claimed by at most one workout,
///   so two short workouts can't both be marked as "on Strava" because of one activity.
///
/// Sport isn't compared. Strava's types and HealthKit's don't line up cleanly (an e-bike ride, a
/// walk recorded as a hike), and two genuinely different workouts overlapping by half their length
/// isn't something a single person does.
public enum StravaActivityMatcher {
    public static let startTolerance: TimeInterval = 10 * 60
    public static let minimumOverlap = 0.5

    /// Workout id → Strava activity id, for every workout found on Strava.
    public static func match(
        _ workouts: [Workout], against activities: [StravaActivitySummary]
    ) -> [String: Int] {
        var matches: [String: Int] = [:]
        var claimed = Set<Int>()

        // Certain matches first, so a fuzzy one can never take an activity that is provably ours.
        let byExternalID = Dictionary(
            activities.compactMap { a in a.externalID.map { ($0, a.id) } },
            uniquingKeysWith: { first, _ in first }
        )
        for workout in workouts {
            if let id = byExternalID[workout.id], !claimed.contains(id) {
                matches[workout.id] = id
                claimed.insert(id)
            }
        }

        // Then every plausible pairing, best overlap first.
        struct Candidate { let workoutID: String; let activityID: Int; let overlap: Double }
        var candidates: [Candidate] = []
        let sorted = activities.sorted { $0.startDate < $1.startDate }
        for workout in workouts where matches[workout.id] == nil {
            for activity in nearby(workout.start, in: sorted) where !claimed.contains(activity.id) {
                let score = overlap(workout, activity)
                if score >= minimumOverlap {
                    candidates.append(Candidate(workoutID: workout.id, activityID: activity.id, overlap: score))
                }
            }
        }
        for candidate in candidates.sorted(by: { $0.overlap > $1.overlap })
        where matches[candidate.workoutID] == nil && !claimed.contains(candidate.activityID) {
            matches[candidate.workoutID] = candidate.activityID
            claimed.insert(candidate.activityID)
        }
        return matches
    }

    /// Fraction of the shorter interval that the two share. A zero-length interval — a workout
    /// with no duration recorded — compares by start time alone.
    static func overlap(_ workout: Workout, _ activity: StravaActivitySummary) -> Double {
        let start = max(workout.start, activity.startDate)
        let end = min(workout.end, activity.end)
        let shared = max(0, end.timeIntervalSince(start))
        let shorter = min(workout.end.timeIntervalSince(workout.start), activity.elapsedTime)
        guard shorter > 0 else {
            return abs(workout.start.timeIntervalSince(activity.startDate)) <= startTolerance ? 1 : 0
        }
        return shared / shorter
    }

    /// Activities starting within the tolerance, by binary search — a seven-year library against
    /// a seven-year Strava history is thousands squared otherwise.
    private static func nearby(_ start: Date, in sorted: [StravaActivitySummary]) -> ArraySlice<StravaActivitySummary> {
        let lower = start.addingTimeInterval(-startTolerance)
        let upper = start.addingTimeInterval(startTolerance)
        var low = 0, high = sorted.count
        while low < high {
            let mid = (low + high) / 2
            if sorted[mid].startDate < lower { low = mid + 1 } else { high = mid }
        }
        var end = low
        while end < sorted.count, sorted[end].startDate <= upper { end += 1 }
        return sorted[low..<end]
    }
}

extension StravaClient {
    /// Every activity that started in the interval, newest first, across as many pages as it
    /// takes. 200 per page is Strava's maximum, so seven years is typically 10–15 read requests.
    public func activities(in interval: DateInterval) async throws -> [StravaActivitySummary] {
        var all: [StravaActivitySummary] = []
        var page = 1
        while true {
            let batch = try await activitiesPage(
                after: interval.start, before: interval.end, page: page, perPage: 200
            )
            all += batch
            // A short page is the last one; asking again would only spend a request on nothing.
            if batch.count < 200 { return all }
            page += 1
        }
    }
}
