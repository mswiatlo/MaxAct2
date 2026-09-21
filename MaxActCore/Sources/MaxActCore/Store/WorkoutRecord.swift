import Foundation
import SwiftData

/// The persisted row for one workout.
///
/// Every field the table sorts, filters or displays is stored directly — denormalised on purpose,
/// so listing thousands of rows never opens a series blob. The heavy per-sample data lives on disk
/// via ``SeriesStore`` and is loaded only for the detail view and for export.
///
/// Fields divide into two kinds, and the distinction is the whole point of ``WorkoutStore/upsert``:
///
/// * **Imported** — from Health Auto Export. Overwritten freely on every re-sync.
/// * **Local** — `stravaState`, `stravaActivityID`, `stravaUploadID`, `lastUploadedAt`,
///   `placeLabel`, `thumbnailFileName`, `hasDetail`. Earned by this app and never derivable from
///   a payload, so a re-sync must not clobber them. Losing `stravaActivityID` in particular would
///   mean re-uploading a workout that is already on Strava.
@Model
public final class WorkoutRecord {
    // MARK: Identity

    /// HealthKit's workout UUID. Unique, and the key every upsert matches on.
    @Attribute(.unique) public var id: String

    // MARK: Imported

    public var activityName: String
    /// `ActivityKind.storageKey`. Stored as a string because `#Predicate` cannot see through an
    /// enum with associated values, and `.other(String)` has one.
    public var kindKey: String
    public var start: Date
    public var end: Date
    public var duration: TimeInterval
    public var distanceMeters: Double?
    public var activeEnergyKilocalories: Double?
    public var totalEnergyKilocalories: Double?
    public var elevationAscendedMeters: Double?
    public var elevationDescendedMeters: Double?
    public var averageSpeedMetersPerSecond: Double?
    public var maximumSpeedMetersPerSecond: Double?
    public var averageHeartRate: Double?
    public var minimumHeartRate: Double?
    public var maximumHeartRate: Double?
    public var isIndoor: Bool?
    public var sourceName: String?
    public var hasRoute: Bool

    // MARK: Local — preserved across re-sync

    /// Coarse place name such as "Vancouver BC", resolved from ``placeCoordinate``.
    ///
    /// Cached here because it is the only thing the list needs and geocoding is documented as
    /// rate-limited. MapKit's own localized form is stored verbatim rather than reassembled from
    /// parts, so it reads correctly outside Canada too.
    public var placeLabel: String?

    /// The route's first fix, **already snapped to a ~1 km grid** by ``PlaceGrid``.
    ///
    /// Stored coarse deliberately: the precise start is where the athlete lives. Kept as two
    /// optional `Double`s rather than a `Coordinate` because SwiftData stores attributes, and an
    /// optional pair keeps "never had a route" distinguishable from "on the equator".
    public var placeLatitude: Double?
    public var placeLongitude: Double?
    public var stravaStateKey: String
    public var stravaFailureReason: String?
    public var stravaActivityID: Int?
    /// Strava's upload id while processing is in flight, persisted so a relaunch resumes polling
    /// instead of re-uploading.
    public var stravaUploadID: Int?
    public var lastUploadedAt: Date?
    public var thumbnailFileName: String?
    /// Whether the second-resolution series with routes has been fetched. Distinct from
    /// `hasRoute`, which only says the workout *has* a route to fetch.
    public var hasDetail: Bool
    public var lastSyncedAt: Date

    public init(workout: Workout, now: Date = .now) {
        id = workout.id
        activityName = workout.kind.displayName
        kindKey = workout.kind.storageKey
        start = workout.start
        end = workout.end
        duration = workout.duration
        distanceMeters = workout.distanceMeters
        activeEnergyKilocalories = workout.activeEnergyKilocalories
        totalEnergyKilocalories = workout.totalEnergyKilocalories
        elevationAscendedMeters = workout.elevationAscendedMeters
        elevationDescendedMeters = workout.elevationDescendedMeters
        averageSpeedMetersPerSecond = workout.averageSpeedMetersPerSecond
        maximumSpeedMetersPerSecond = workout.maximumSpeedMetersPerSecond
        averageHeartRate = workout.averageHeartRate
        minimumHeartRate = workout.minimumHeartRate
        maximumHeartRate = workout.maximumHeartRate
        isIndoor = workout.isIndoor
        sourceName = workout.sourceName
        hasRoute = workout.hasRoute

        placeLabel = nil
        placeLatitude = nil
        placeLongitude = nil
        stravaStateKey = StravaState.notUploaded.storageKey
        stravaFailureReason = nil
        stravaActivityID = nil
        stravaUploadID = nil
        lastUploadedAt = nil
        thumbnailFileName = nil
        hasDetail = false
        lastSyncedAt = now
    }

    /// Applies a freshly imported payload, touching **only** imported fields.
    ///
    /// `hasRoute` is OR-ed rather than assigned: the list pass is fetched with
    /// `includeRoutes: false` and so always reports `false`, and a plain assignment would erase
    /// the knowledge that a route exists every time a window is re-listed.
    public func applyImported(_ workout: Workout, now: Date = .now) {
        activityName = workout.kind.displayName
        kindKey = workout.kind.storageKey
        start = workout.start
        end = workout.end
        duration = workout.duration
        distanceMeters = workout.distanceMeters ?? distanceMeters
        activeEnergyKilocalories = workout.activeEnergyKilocalories ?? activeEnergyKilocalories
        totalEnergyKilocalories = workout.totalEnergyKilocalories ?? totalEnergyKilocalories
        elevationAscendedMeters = workout.elevationAscendedMeters ?? elevationAscendedMeters
        elevationDescendedMeters = workout.elevationDescendedMeters ?? elevationDescendedMeters
        averageSpeedMetersPerSecond = workout.averageSpeedMetersPerSecond ?? averageSpeedMetersPerSecond
        maximumSpeedMetersPerSecond = workout.maximumSpeedMetersPerSecond ?? maximumSpeedMetersPerSecond
        averageHeartRate = workout.averageHeartRate ?? averageHeartRate
        minimumHeartRate = workout.minimumHeartRate ?? minimumHeartRate
        maximumHeartRate = workout.maximumHeartRate ?? maximumHeartRate
        isIndoor = workout.isIndoor ?? isIndoor
        sourceName = workout.sourceName ?? sourceName
        hasRoute = hasRoute || workout.hasRoute
        lastSyncedAt = now
    }

    public var kind: ActivityKind {
        ActivityKind(storageKey: kindKey)
    }

    public var stravaState: StravaState {
        get { StravaState(storageKey: stravaStateKey, failureReason: stravaFailureReason) }
        set {
            stravaStateKey = newValue.storageKey
            stravaFailureReason = newValue.failureReason
        }
    }

    /// The value type the UI works with, so `@Model` objects never escape the store's actor.
    public var snapshot: Workout {
        Workout(
            id: id,
            kind: kind,
            start: start,
            end: end,
            duration: duration,
            distanceMeters: distanceMeters,
            activeEnergyKilocalories: activeEnergyKilocalories,
            totalEnergyKilocalories: totalEnergyKilocalories,
            elevationAscendedMeters: elevationAscendedMeters,
            elevationDescendedMeters: elevationDescendedMeters,
            averageSpeedMetersPerSecond: averageSpeedMetersPerSecond,
            maximumSpeedMetersPerSecond: maximumSpeedMetersPerSecond,
            averageHeartRate: averageHeartRate,
            minimumHeartRate: minimumHeartRate,
            maximumHeartRate: maximumHeartRate,
            isIndoor: isIndoor,
            sourceName: sourceName,
            hasRoute: hasRoute
        )
    }
}

extension WorkoutRecord {
    /// The snapped start, or `nil` if no route has been stored yet.
    public var placeCoordinate: Coordinate? {
        guard let placeLatitude, let placeLongitude else { return nil }
        return Coordinate(latitude: placeLatitude, longitude: placeLongitude)
    }
}

/// A row as the UI consumes it: the imported summary plus the local state, all value types.
public struct WorkoutListItem: Identifiable, Hashable, Sendable {
    public let workout: Workout
    public let placeLabel: String?
    public let stravaState: StravaState
    public let stravaActivityID: Int?
    public let hasDetail: Bool
    public let thumbnailFileName: String?

    public var id: String { workout.id }

    init(record: WorkoutRecord) {
        workout = record.snapshot
        placeLabel = record.placeLabel
        stravaState = record.stravaState
        stravaActivityID = record.stravaActivityID
        hasDetail = record.hasDetail
        thumbnailFileName = record.thumbnailFileName
    }
}
