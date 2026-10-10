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
///   `placeLabel`, `thumbnailFileName`, `hasDetail`, `tagNames`. Earned by this app and never derivable from
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

    /// Hidden text that makes this workout findable by region and country — "British Columbia",
    /// "Canada" — while ``placeLabel`` stays short. Already folded for case and diacritics; see
    /// ``PlaceTerms``. Defaulted so the existing store migrates without a mapping model.
    public var placeSearchTerms: String?

    /// Which ``PlaceTerms/version`` built ``placeSearchTerms``. `0` means "never resolved", which
    /// is what every row written before this existed reports — and what makes them re-resolve
    /// themselves, one request per place rather than per workout.
    public var placeTermsVersion: Int = 0
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

    /// User and Strava-backed tags (``WorkoutTag``). Local state: a re-sync never touches it.
    /// Default declared here so the existing store migrates without a mapping model.
    public var tagNames: [String] = []

    /// A Strava-backed tag was edited here on a workout already on Strava, and the change hasn't
    /// reached Strava yet. While set, a sync-status check must not overwrite the local value with
    /// Strava's stale one — that would silently undo the user's edit.
    public var stravaFlagsPending: Bool = false

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
        placeSearchTerms = nil
        placeTermsVersion = 0
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
    /// Folded search text for region and country. Never displayed.
    public let placeSearchTerms: String?
    /// Strava-backed first, then alphabetical.
    public let tags: [String]
    public let stravaFlagsPending: Bool
    public let stravaState: StravaState
    public let stravaActivityID: Int?
    public let hasDetail: Bool
    public let thumbnailFileName: String?

    public var id: String { workout.id }

    init(record: WorkoutRecord) {
        workout = record.snapshot
        placeLabel = record.placeLabel
        placeSearchTerms = record.placeSearchTerms
        tags = WorkoutTag.sorted(record.tagNames)
        stravaFlagsPending = record.stravaFlagsPending
        stravaState = record.stravaState
        stravaActivityID = record.stravaActivityID
        hasDetail = record.hasDetail
        thumbnailFileName = record.thumbnailFileName
    }
}

extension WorkoutListItem {
    public var sourceName: String? { workout.sourceName }

    /// Free-text match over the fields a person would plausibly type: activity, place, source,
    /// tags. Deliberately not the id — nobody searches for a UUID.
    ///
    /// Folded for case **and diacritics**, so "geneve" finds a ride in Genève. `placeSearchTerms`
    /// is what makes "British Columbia" and "Canada" find rides whose visible label only says
    /// "Greater Vancouver BC"; it is stored pre-folded, so it is compared directly.
    public func matches(searchText: String) -> Bool {
        guard !searchText.isEmpty else { return true }
        let needle = PlaceTerms.folded(searchText)
        if PlaceTerms.contains(workout.kind.displayName, foldedNeedle: needle) { return true }
        if let placeLabel, PlaceTerms.contains(placeLabel, foldedNeedle: needle) { return true }
        if let placeSearchTerms, placeSearchTerms.contains(needle) { return true }
        if let sourceName, PlaceTerms.contains(sourceName, foldedNeedle: needle) { return true }
        if tags.contains(where: { PlaceTerms.contains($0, foldedNeedle: needle) }) { return true }
        return false
    }
}
