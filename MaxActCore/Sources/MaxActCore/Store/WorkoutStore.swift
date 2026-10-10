import Foundation
import SwiftData

/// The workout database.
///
/// A `@ModelActor`, so every `WorkoutRecord` stays behind the actor boundary — `@Model` classes
/// are not `Sendable`, and handing one to the UI would be a data race. Everything crossing out is
/// a value type (``WorkoutListItem``, ``Workout``).
@ModelActor
public actor WorkoutStore {
    /// What one upsert did, so a sync can report meaningfully rather than just "done".
    public struct UpsertSummary: Sendable, Equatable {
        public var inserted = 0
        public var updated = 0
        public var seriesStored = 0

        public var total: Int { inserted + updated }
    }

    // MARK: - Ingest

    /// Inserts or updates workouts, **preserving local state**.
    ///
    /// Idempotent by construction: matching is on the HealthKit UUID, and an existing row has only
    /// its imported fields rewritten. Re-listing a window — which happens whenever a chunk is
    /// interrupted and retried — therefore cannot duplicate rows, and cannot lose Strava state,
    /// place labels or cached thumbnails.
    ///
    /// Series are written only when non-empty: the list pass carries none, and blindly saving
    /// would replace a previously fetched detail blob with an empty one.
    @discardableResult
    public func upsert(
        _ ingested: [IngestedWorkout],
        seriesStore: SeriesStore? = nil,
        now: Date = .now
    ) async throws -> UpsertSummary {
        var summary = UpsertSummary()

        for item in ingested {
            let id = item.workout.id
            let existing = try modelContext.fetch(
                FetchDescriptor<WorkoutRecord>(predicate: #Predicate { $0.id == id })
            ).first

            let record: WorkoutRecord
            if let existing {
                existing.applyImported(item.workout, now: now)
                record = existing
                summary.updated += 1
            } else {
                record = WorkoutRecord(workout: item.workout, now: now)
                modelContext.insert(record)
                summary.inserted += 1
            }

            if let seriesStore, !item.series.isEmpty {
                try await seriesStore.save(item.series)
                record.hasDetail = !item.series.route.isEmpty || !item.series.heartRate.isEmpty
                if !item.series.route.isEmpty { record.hasRoute = true }
                summary.seriesStored += 1

                // Snapped here, at the one point where a precise route is in hand, so the
                // database never holds the exact start. Only set when absent: re-snapping an
                // unchanged route would be churn, and the label is keyed off this value.
                if record.placeCoordinate == nil,
                   let start = PlaceGrid.start(of: item.series.route) {
                    record.placeLatitude = start.latitude
                    record.placeLongitude = start.longitude
                }
            }
        }

        try modelContext.save()
        return summary
    }

    // MARK: - Reads

    public func allItems(newestFirst: Bool = true) throws -> [WorkoutListItem] {
        var descriptor = FetchDescriptor<WorkoutRecord>()
        descriptor.sortBy = [SortDescriptor(\.start, order: newestFirst ? .reverse : .forward)]
        return try modelContext.fetch(descriptor).map(WorkoutListItem.init(record:))
    }

    public func count() throws -> Int {
        try modelContext.fetchCount(FetchDescriptor<WorkoutRecord>())
    }

    public func item(id: String) throws -> WorkoutListItem? {
        try record(id: id).map(WorkoutListItem.init(record:))
    }

    /// Workouts not yet on Strava — the default batch-upload selection.
    public func itemsNotOnStrava() throws -> [WorkoutListItem] {
        let onStrava = [StravaState.uploaded.storageKey, StravaState.duplicate.storageKey]
        var descriptor = FetchDescriptor<WorkoutRecord>(
            predicate: #Predicate { !onStrava.contains($0.stravaStateKey) }
        )
        descriptor.sortBy = [SortDescriptor(\.start, order: .reverse)]
        return try modelContext.fetch(descriptor).map(WorkoutListItem.init(record:))
    }

    // MARK: - Tags

    /// Every tag in use, plus the two Strava-backed ones even if nothing carries them yet, so they
    /// are always offered.
    public func allTagNames() throws -> [String] {
        let used = try modelContext.fetch(FetchDescriptor<WorkoutRecord>()).flatMap(\.tagNames)
        return WorkoutTag.sorted(Array(Set(used).union(WorkoutTag.stravaBacked)))
    }

    /// Adds a tag to every listed workout. Returns the ids of workouts already on Strava whose
    /// Strava flags therefore need pushing — empty for a local-only tag.
    @discardableResult
    public func addTag(_ name: String, to workoutIDs: [String]) throws -> [String] {
        try editTags(of: workoutIDs, touching: name) { tags in
            tags.contains(name) ? nil : tags + [name]
        }
    }

    @discardableResult
    public func removeTag(_ name: String, from workoutIDs: [String]) throws -> [String] {
        try editTags(of: workoutIDs, touching: name) { tags in
            tags.contains(name) ? tags.filter { $0 != name } : nil
        }
    }

    private func editTags(
        of workoutIDs: [String], touching name: String, _ change: ([String]) -> [String]?
    ) throws -> [String] {
        var needsPush: [String] = []
        for id in workoutIDs {
            guard let record = try record(id: id), let updated = change(record.tagNames) else { continue }
            record.tagNames = WorkoutTag.sorted(updated)
            // A Strava-backed tag on a workout Strava already has: mark it, so the push isn't
            // lost and a status check doesn't put the old value back before it happens.
            if WorkoutTag.isStravaBacked(name), record.stravaActivityID != nil, record.stravaState.isOnStrava {
                record.stravaFlagsPending = true
                needsPush.append(id)
            }
        }
        try modelContext.save()
        return needsPush
    }

    /// Mirrors Strava's commute/trainer flags onto the workouts linked to those activities.
    ///
    /// Strava is the authority for a synced workout's flags — they may have been set on the
    /// website or by the watch — *except* while a local edit is still waiting to be pushed, which
    /// would otherwise be undone. Returns how many workouts changed.
    @discardableResult
    public func applyStravaFlags(_ flags: [Int: StravaFlags]) throws -> Int {
        let records = try modelContext.fetch(FetchDescriptor<WorkoutRecord>(
            predicate: #Predicate { $0.stravaActivityID != nil && $0.stravaFlagsPending == false }
        ))
        var changed = 0
        for record in records {
            guard let id = record.stravaActivityID, let flag = flags[id],
                  let updated = WorkoutTag.applying(commute: flag.commute, trainer: flag.trainer,
                                                    to: record.tagNames)
            else { continue }
            record.tagNames = updated
            changed += 1
        }
        if changed > 0 { try modelContext.save() }
        return changed
    }

    /// Local edits to Strava-backed tags not yet on Strava: what to send for each.
    public func pendingStravaFlags() throws -> [(workoutID: String, activityID: Int, flags: StravaFlags)] {
        try modelContext.fetch(FetchDescriptor<WorkoutRecord>(
            predicate: #Predicate { $0.stravaFlagsPending == true && $0.stravaActivityID != nil }
        )).compactMap { record in
            record.stravaActivityID.map { (record.id, $0, StravaFlags(tags: record.tagNames)) }
        }
    }

    public func clearStravaFlagsPending(_ workoutID: String) throws {
        guard let record = try record(id: workoutID) else { return }
        record.stravaFlagsPending = false
        try modelContext.save()
    }

    /// Records workouts found already on Strava, returning how many changed.
    ///
    /// Only touches workouts MaxAct hasn't itself put there: not-uploaded, failed, or queued.
    /// One we uploaded keeps its "Uploaded" state and its own activity id, and one mid-upload is
    /// left for its upload to settle — a background check must never rewrite either.
    @discardableResult
    public func markAlreadyOnStrava(_ matches: [String: Int], now: Date = .now) throws -> Int {
        let replaceable: Set<String> = [
            StravaState.notUploaded.storageKey, StravaState.queued.storageKey,
            StravaState.failed(reason: "").storageKey,
        ]
        var changed = 0
        for (workoutID, activityID) in matches {
            guard let record = try record(id: workoutID),
                  replaceable.contains(record.stravaStateKey) else { continue }
            record.stravaState = .duplicate
            record.stravaActivityID = activityID
            record.lastUploadedAt = now
            changed += 1
        }
        if changed > 0 { try modelContext.save() }
        return changed
    }

    /// Uploads a previous run accepted but didn't see finish. Resumed by polling the saved id —
    /// uploading again would only earn a "duplicate" and spend a write.
    public func itemsUploadingToStrava() throws -> [(id: String, uploadID: Int)] {
        let uploading = StravaState.uploading.storageKey
        let descriptor = FetchDescriptor<WorkoutRecord>(
            predicate: #Predicate { $0.stravaStateKey == uploading && $0.stravaUploadID != nil }
        )
        return try modelContext.fetch(descriptor).compactMap { record in
            record.stravaUploadID.map { (record.id, $0) }
        }
    }

    /// Workouts whose detail has not been fetched, oldest-listed first — the backlog for the lazy
    /// second pass.
    public func itemsNeedingDetail(limit: Int? = nil) throws -> [WorkoutListItem] {
        var descriptor = FetchDescriptor<WorkoutRecord>(
            predicate: #Predicate { $0.hasDetail == false }
        )
        descriptor.sortBy = [SortDescriptor(\.start, order: .reverse)]
        if let limit { descriptor.fetchLimit = limit }
        return try modelContext.fetch(descriptor).map(WorkoutListItem.init(record:))
    }

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
    public func itemsNeedingPlace(limit: Int? = nil) throws -> [(id: String, coordinate: Coordinate)] {
        let currentVersion = PlaceTerms.version
        var descriptor = FetchDescriptor<WorkoutRecord>(
            predicate: #Predicate {
                $0.placeLatitude != nil
                    && ($0.placeLabel == nil || $0.placeTermsVersion < currentVersion)
            }
        )
        descriptor.sortBy = [SortDescriptor(\.start, order: .reverse)]
        if let limit { descriptor.fetchLimit = limit }
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

    // MARK: - Local state

    public func setStravaState(
        _ state: StravaState,
        activityID: Int? = nil,
        uploadID: Int? = nil,
        for workoutID: String,
        now: Date = .now
    ) throws {
        guard let record = try record(id: workoutID) else { return }
        record.stravaState = state
        // Only overwrite the ids when given one: a poll that reports progress shouldn't erase the
        // activity id a previous step established.
        if let activityID { record.stravaActivityID = activityID }
        if let uploadID { record.stravaUploadID = uploadID }
        if state.isOnStrava { record.lastUploadedAt = now }
        try modelContext.save()
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
    /// nothing structural, which legitimately leaves `searchTerms` nil.
    public func setPlace(
        label: String?,
        searchTerms: String? = nil,
        for workoutID: String
    ) throws {
        guard let record = try record(id: workoutID) else { return }
        record.placeLabel = label
        record.placeSearchTerms = searchTerms
        record.placeTermsVersion = PlaceTerms.version
        try modelContext.save()
    }

    /// Internal, and only so a test can reproduce a library resolved before a given terms version.
    /// Production code always stamps the current version through ``setPlace(label:searchTerms:for:)``.
    func setPlaceTermsVersion(_ version: Int, for workoutID: String) throws {
        guard let record = try record(id: workoutID) else { return }
        record.placeTermsVersion = version
        try modelContext.save()
    }

    public func setThumbnailFileName(_ name: String?, for workoutID: String) throws {
        guard let record = try record(id: workoutID) else { return }
        record.thumbnailFileName = name
        try modelContext.save()
    }

    /// Reconciles the `hasDetail` flags against what is actually on disk. Cheap insurance against
    /// the database and the blob directory drifting apart — a blob deleted outside the app, or a
    /// database restored from backup.
    @discardableResult
    public func reconcileDetailFlags(with seriesStore: SeriesStore) async throws -> Int {
        var corrected = 0
        for record in try modelContext.fetch(FetchDescriptor<WorkoutRecord>()) {
            let onDisk = await seriesStore.has(record.id)
            if record.hasDetail != onDisk {
                record.hasDetail = onDisk
                corrected += 1
            }
        }
        if corrected > 0 { try modelContext.save() }
        return corrected
    }

    /// Removes every workout. Returns how many were deleted, so the caller can report it.
    ///
    /// Series blobs and thumbnails live outside the database and are **not** touched here — the
    /// caller must clear those too, or the next sync re-imports summaries that silently adopt
    /// the orphaned blobs of deleted workouts, since both are keyed on the same HealthKit UUID.
    @discardableResult
    public func deleteAll() throws -> Int {
        let records = try modelContext.fetch(FetchDescriptor<WorkoutRecord>())
        for record in records { modelContext.delete(record) }
        try modelContext.save()
        return records.count
    }

    public func delete(id: String) throws {
        guard let record = try record(id: id) else { return }
        modelContext.delete(record)
        try modelContext.save()
    }

    private func record(id: String) throws -> WorkoutRecord? {
        try modelContext.fetch(
            FetchDescriptor<WorkoutRecord>(predicate: #Predicate { $0.id == id })
        ).first
    }
}

extension WorkoutStore {
    /// The schema, in one place so the app and the tests cannot disagree about it.
    public static var schema: Schema { Schema([WorkoutRecord.self]) }

    public static func container(inMemory: Bool = false) throws -> ModelContainer {
        try ModelContainer(
            for: schema,
            configurations: ModelConfiguration(schema: schema, isStoredInMemoryOnly: inMemory)
        )
    }
}
