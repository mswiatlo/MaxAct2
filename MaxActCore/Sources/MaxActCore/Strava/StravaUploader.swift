import Foundation

/// Somewhere a workout can be sent. Strava is the only one today.
///
/// Exists so a second destination (TrainingPeaks — see PLAN.md known issue 7) is a new
/// conformance rather than a rewrite. Note the limit of that: upload *state* is still stored in
/// Strava-named fields on `WorkoutRecord`, and a second destination would need per-destination
/// state there. That migration was deliberately not done speculatively.
public protocol WorkoutDestination: Sendable {
    var displayName: String { get }

    /// Sends a workout and follows it to a settled state. `uploadStarted` reports the remote id
    /// as soon as there is one, so it can be persisted before the (slow) wait for processing.
    func send(
        _ workout: Workout, series: WorkoutSeries,
        uploadStarted: @Sendable (Int) async -> Void
    ) async throws -> UploadResult

    /// Picks up an upload a previous run started but didn't see finish.
    func resume(uploadID: Int, workout: Workout) async throws -> UploadResult
}

public struct UploadResult: Sendable, Equatable {
    public let state: StravaState
    public let activityID: Int?
    public let uploadID: Int?
    /// Something that went wrong after the workout safely arrived — e.g. the sport couldn't be
    /// corrected. Reported rather than swallowed, and not a failure of the upload itself.
    public let warning: String?

    public init(state: StravaState, activityID: Int?, uploadID: Int?, warning: String?) {
        self.state = state
        self.activityID = activityID
        self.uploadID = uploadID
        self.warning = warning
    }
}

/// Uploads one workout to Strava and follows it through processing.
///
/// The sequence, each step for a reason:
/// 1. Write the TCX and `POST /uploads` with `external_id` = the HealthKit UUID, so a re-upload is
///    recognised server-side as a duplicate instead of creating a second activity.
/// 2. Hand the upload id back immediately, so it's persisted before the wait: a relaunch then
///    resumes polling rather than uploading again.
/// 3. Poll `GET /uploads/{id}` on a widening schedule until it settles. Polls spend the *read*
///    bucket, so the schedule starts quick (processing usually takes a few seconds) and backs off.
/// 4. If the sport needs correcting — anything but a run or ride — `PUT sport_type`.
public struct StravaUploader: WorkoutDestination {
    public let displayName = "Strava"

    private let client: StravaClient
    private let timeZone: TimeZone
    private let sleep: @Sendable (TimeInterval) async throws -> Void

    /// Seconds before each poll. Totals about three minutes before giving up *for now* — the
    /// upload stays `.uploading` with its id saved, and is resumed later rather than repeated.
    static let pollSchedule: [TimeInterval] = [2, 2, 3, 5, 8, 10, 10, 15, 15, 20, 30, 30, 30]

    public init(
        client: StravaClient,
        timeZone: TimeZone = .current,
        sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { try await Task.sleep(for: .seconds($0)) }
    ) {
        self.client = client
        self.timeZone = timeZone
        self.sleep = sleep
    }

    public func send(
        _ workout: Workout, series: WorkoutSeries,
        uploadStarted: @Sendable (Int) async -> Void
    ) async throws -> UploadResult {
        let document = TCXWriter.document(for: workout, series: series)
        let response = try await client.upload(
            file: Data(document.utf8),
            fileName: "\(workout.id).tcx",
            name: Self.activityName(for: workout, in: timeZone),
            description: nil,
            externalID: workout.id,
            commute: false,
            trainer: workout.isIndoor == true
        )
        await uploadStarted(response.id)
        return try await settle(response, workout: workout)
    }

    public func resume(uploadID: Int, workout: Workout) async throws -> UploadResult {
        try await settle(try await client.uploadStatus(id: uploadID), workout: workout)
    }

    private func settle(_ first: StravaUploadResponse, workout: Workout) async throws -> UploadResult {
        var response = first
        var schedule = Self.pollSchedule[...]
        while case .processing = response.outcome, let delay = schedule.popFirst() {
            try await sleep(delay)
            response = try await client.uploadStatus(id: response.id)
        }

        switch response.outcome {
        case .processing:
            return UploadResult(state: .uploading, activityID: nil, uploadID: response.id, warning: nil)
        case .failed(let reason):
            return UploadResult(state: .failed(reason: reason), activityID: nil, uploadID: response.id, warning: nil)
        case .duplicate(let activityID):
            return UploadResult(state: .duplicate, activityID: activityID, uploadID: response.id, warning: nil)
        case .ready(let activityID):
            var warning: String?
            if workout.kind.stravaNeedsSportCorrection {
                do {
                    try await client.updateActivity(id: activityID, sportType: workout.kind.stravaSportType)
                } catch {
                    warning = "Uploaded, but the activity type couldn't be set to "
                        + "\(workout.kind.stravaSportType): \(error)"
                }
            }
            return UploadResult(state: .uploaded, activityID: activityID, uploadID: response.id, warning: warning)
        }
    }

    /// "Evening Walk", in the style Strava names activities itself.
    ///
    /// Named by us rather than left to Strava because Strava would name it from the *inferred*
    /// type — so a walk, uploaded as TCX sport "Other", would arrive as "Evening Workout" and keep
    /// that name even after its type is corrected.
    static func activityName(for workout: Workout, in timeZone: TimeZone) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let hour = calendar.component(.hour, from: workout.start)
        let period = switch hour {
        case 5..<11: "Morning"
        case 11..<14: "Lunch"
        case 14..<17: "Afternoon"
        case 17..<21: "Evening"
        default: "Night"
        }
        let noun: String = switch workout.kind {
        case .indoorCycling: "Indoor Ride"
        case .strengthTraining: "Weight Training"
        default: workout.kind.stravaSportType
        }
        return "\(period) \(noun)"
    }
}
