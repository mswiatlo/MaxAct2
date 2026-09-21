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

    public func setPlaceLabel(_ label: String?, for workoutID: String) throws {
        guard let record = try record(id: workoutID) else { return }
        record.placeLabel = label
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
