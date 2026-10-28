import Foundation
import SwiftData

/// Places: snapped starts, names, and the search terms built from them. Split out of `WorkoutStore.swift` (issue 42).
extension WorkoutStore {
    /// Workouts with a coarse start whose place still needs resolving, newest first.
    ///
    /// That means **either** no name yet **or** search terms built by an older
    /// ``PlaceTerms/version``. The second case is what backfills region and country onto a library
    /// resolved before those existed: it costs one geocoder request per distinct ~1 km cell, not
    /// per workout, because the resolver caches by cell.
    ///
    /// Indoor workouts are excluded by having no route to snap in the first place, so there is no
    /// need to filter on `isIndoor` — and filtering on it would be wrong for an outdoor workout
    /// the watch happened to mark indoor.
    public func itemsNeedingPlace(limit: Int? = nil, offset: Int = 0) throws -> [(id: String, coordinate: Coordinate)] {
        let currentVersion = PlaceTerms.version
        var descriptor = FetchDescriptor<WorkoutRecord>(
            predicate: #Predicate {
                $0.placeLatitude != nil
                    && ($0.placeLabel == nil || $0.placeTermsVersion < currentVersion)
            }
        )
        descriptor.sortBy = [SortDescriptor(\.start, order: .reverse)]
        if let limit { descriptor.fetchLimit = limit }
        descriptor.fetchOffset = offset
        return try modelContext.fetch(descriptor).compactMap { record in
            record.placeCoordinate.map { (record.id, $0) }
        }
    }

    /// Backfills the snapped start for records that predate it, reading the stored series.
    ///
    /// Without this, everything synced before Phase 6 would need a re-sync to get a place. Returns
    /// how many gained a coordinate.
    @discardableResult
    public func backfillPlaceCoordinates(seriesStore: SeriesStore) async throws -> Int {
        let descriptor = FetchDescriptor<WorkoutRecord>(
            predicate: #Predicate { $0.placeLatitude == nil && $0.hasDetail == true }
        )
        var filled = 0
        for record in try modelContext.fetch(descriptor) {
            guard let series = await seriesStore.loadIfAvailable(record.id),
                  let start = PlaceGrid.start(of: series.route)
            else { continue }
            record.placeLatitude = start.latitude
            record.placeLongitude = start.longitude
            filled += 1
        }
        if filled > 0 { try modelContext.save() }
        return filled
    }

    /// The workout's coarsened start, if a route has been stored. Already snapped — there is no
    /// API here that returns the precise one.
    public func placeCoordinate(for workoutID: String) throws -> Coordinate? {
        try record(id: workoutID)?.placeCoordinate
    }

    /// Stores a resolved place: the short visible label, and the hidden region/country terms.
    ///
    /// Stamping the version here is what stops a resolved row coming back round in
    /// ``itemsNeedingPlace(limit:)`` for ever — including when the geocoder knew a name but
    /// nothing structural, which legitimately leaves `parts` nil.
    public func setPlace(
        label: String?,
        parts: PlaceDescription? = nil,
        timeZone: String? = nil,
        for workoutID: String
    ) throws {
        guard let record = try record(id: workoutID) else { return }
        record.placeLabel = label
        record.placeTimeZone = timeZone
        record.placeSearchTerms = parts.flatMap(PlaceTerms.searchTerms(for:))
        record.placeCity = parts?.city
        record.placeSubdivision = parts?.subdivision
        record.placeCountry = parts?.country
        record.placeTermsVersion = PlaceTerms.version
        try modelContext.save()
    }

    /// Gives places MapKit reported without a subdivision the one their city agrees on.
    ///
    /// A pure database pass — no geocoding — run after each round of resolving, so it works
    /// whatever order places resolved in and across launches: the UBC ride can resolve first and
    /// pick up "BC" once any other Vancouver ride has. See
    /// ``PlaceTerms/lendableSubdivisions(from:)`` for when it declines to guess.
    ///
    /// The label gains the subdivision only if it was the bare city, which is what MapKit's empty
    /// context leaves behind; a label MapKit composed itself is kept. Returns how many changed.
    @discardableResult
    public func borrowMissingSubdivisions() throws -> Int {
        let records = try modelContext.fetch(FetchDescriptor<WorkoutRecord>(
            predicate: #Predicate { $0.placeCity != nil && $0.placeCountry != nil }
        ))
        let lendable = PlaceTerms.lendableSubdivisions(from: records.compactMap(\.placeParts))
        guard !lendable.isEmpty else { return 0 }

        var changed = 0
        for record in records {
            guard let parts = record.placeParts,
                  let filled = PlaceTerms.borrowingSubdivision(for: parts, from: lendable),
                  let city = filled.city, let subdivision = filled.subdivision
            else { continue }
            record.placeSubdivision = subdivision
            record.placeSearchTerms = PlaceTerms.searchTerms(for: filled)
            if record.placeLabel == nil || record.placeLabel == city {
                record.placeLabel = "\(city) \(subdivision)"
            }
            changed += 1
        }
        if changed > 0 { try modelContext.save() }
        return changed
    }

    /// Internal, and only so a test can reproduce a library resolved before a given terms version.
    /// Production code always stamps the current version through ``setPlace(label:parts:for:)``.
    func setPlaceTermsVersion(_ version: Int, for workoutID: String) throws {
        guard let record = try record(id: workoutID) else { return }
        record.placeTermsVersion = version
        try modelContext.save()
    }
}
