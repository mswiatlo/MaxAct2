import Foundation
import SwiftData

/// Strava state: what's uploaded, linked, pending or in flight. Split out of `WorkoutStore.swift` (issue 42).
extension WorkoutStore {
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
                                                    race: flag.race, to: record.tagNames)
            else { continue }
            record.tagNames = updated
            changed += 1
        }
        if changed > 0 { try modelContext.save() }
        return changed
    }

    /// Local edits to Strava-backed tags not yet on Strava: what to send for each.
    public func pendingStravaFlags() throws -> [(workoutID: String, activityID: Int, kind: ActivityKind, flags: StravaFlags)] {
        try modelContext.fetch(FetchDescriptor<WorkoutRecord>(
            predicate: #Predicate { $0.stravaFlagsPending == true && $0.stravaActivityID != nil }
        )).compactMap { record in
            record.stravaActivityID.map { (record.id, $0, record.snapshot.kind, StravaFlags(tags: record.tagNames)) }
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

    /// Workouts this app believes are on Strava whose activity isn't in `listed`, as
    /// `activityID → workoutID`. Candidates for ``markRemovedFromStrava(_:)``, **not** proof: the
    /// caller confirms each one with Strava before acting.
    ///
    /// Only rows with an activity id — an upload still processing has none yet, so it can't be
    /// missing from anything — and only workouts that **started within `span`**, the window the
    /// listing covered. Outside it, absence means nothing: the upload pre-check lists just the
    /// selection's dates, and without this every other synced workout would look deleted.
    public func syncedActivities(
        missingFrom listed: Set<Int>, startingWithin span: DateInterval
    ) throws -> [Int: String] {
        let uploaded = StravaState.uploaded.storageKey
        let duplicate = StravaState.duplicate.storageKey
        let (from, to) = (span.start, span.end)
        let descriptor = FetchDescriptor<WorkoutRecord>(predicate: #Predicate {
            ($0.stravaStateKey == uploaded || $0.stravaStateKey == duplicate)
                && $0.stravaActivityID != nil
                && $0.start >= from && $0.start <= to
        })
        var missing: [Int: String] = [:]
        for record in try modelContext.fetch(descriptor) {
            guard let activityID = record.stravaActivityID, !listed.contains(activityID) else { continue }
            missing[activityID] = record.id
        }
        return missing
    }

    /// Returns workouts whose activity was deleted on Strava to "not on Strava".
    ///
    /// Clears the activity and upload ids — the link would lead nowhere — and any pending flag
    /// push, which has nothing left to push to. Tags stay: they're local, and Commute is still
    /// true of the ride. Returns how many changed.
    @discardableResult
    public func markRemovedFromStrava(_ workoutIDs: [String]) throws -> Int {
        var changed = 0
        for workoutID in workoutIDs {
            guard let record = try record(id: workoutID), record.stravaState.isOnStrava else { continue }
            record.stravaState = .notUploaded
            record.stravaActivityID = nil
            record.stravaUploadID = nil
            record.lastUploadedAt = nil
            record.stravaFlagsPending = false
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
}
