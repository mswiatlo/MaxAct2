import Foundation
import MaxActCore
import os

/// Strava: connecting, checking what's already there, uploading, tag edits and route fills.
/// Split out of `AppModel.swift` (issue 39).
extension AppModel {
    /// Sends Commute/Trainer edits on already-synced workouts to Strava. One write each.
    ///
    /// Quiet unless it fails: tagging shouldn't light up a progress banner. If anything else is
    /// running it simply waits — the edits stay marked pending, and the next check or upload batch
    /// pushes them first, so nothing is lost and no stale value can overwrite them meanwhile.
    func pushPendingStravaFlags() {
        guard isStravaConnected, !syncStatus.isRunning, flagPushTask == nil else { return }
        flagPushTask = Task {
            defer { flagPushTask = nil }
            if let error = await sendPendingStravaFlags() { reportQuietly(error) }
            await refreshItems()
        }
    }

    /// Returns a description of the first failure, if any; everything that succeeded is cleared.
    func sendPendingStravaFlags() async -> String? {
        let pending: [(workoutID: String, activityID: Int, kind: ActivityKind, flags: StravaFlags)]
        do {
            pending = try await store.pendingStravaFlags()
        } catch {
            // Was read as "nothing pending" — a success — so the edits silently waited (issue 40).
            return "Couldn't read the tag edits waiting for Strava: \(error.localizedDescription)"
        }
        for entry in pending {
            do {
                var update = StravaActivityUpdate(commute: entry.flags.commute, trainer: entry.flags.trainer)
                // Race (issue 16), for sports that have it on Strava. Setting one needs no read;
                // clearing one checks Strava's current type first, so a Long Run or Workout set
                // there isn't reset — one extra read, only for runs and rides without the tag.
                if StravaRace.raceValue(for: entry.kind) != nil {
                    let race = entry.flags.race == true
                    let current = race ? nil : try await strava.workoutType(ofActivity: entry.activityID)
                    update.workoutType = StravaRace.value(toSend: race, for: entry.kind, current: current)
                }
                try await strava.updateActivity(id: entry.activityID, update)
                do {
                    try await store.clearStravaFlagsPending(entry.workoutID)
                } catch {
                    // Harmless — the same values are sent again next time — but worth knowing.
                    Self.log.error("Couldn't clear sent tag edits for \(entry.workoutID, privacy: .public): \(String(describing: error), privacy: .public)")
                }
            } catch {
                return "Couldn't update tags on Strava: \(Self.describeStravaError(error)). "
                    + "They'll be sent again with the next check or upload."
            }
        }
        return nil
    }

    /// Re-reads what the Keychain holds, for the Settings pane and for enabling Upload.
    func refreshStravaConnection() async {
        let credentials = await stravaSecrets.credentials()
        isStravaConfigured = credentials?.isComplete ?? false
        let tokens = await stravaSecrets.tokens()
        stravaReadProblem = await stravaSecrets.readProblem()
        // A connection with no name still counts — the name is cosmetic, the token isn't.
        stravaAthlete = tokens.map { $0.athleteName?.isEmpty == false ? $0.athleteName! : "Strava athlete" }
    }

    func saveStravaCredentials(clientID: String, clientSecret: String) async throws {
        let credentials = StravaCredentials(clientID: clientID, clientSecret: clientSecret)
        try await stravaSecrets.save(credentials: credentials.isComplete ? credentials : nil)
        await refreshStravaConnection()
    }

    /// The approval page, with a fresh `state` the callback must echo back.
    func stravaAuthorizationRequest() async -> (url: URL, state: String)? {
        guard let credentials = await stravaSecrets.credentials(), credentials.isComplete else { return nil }
        let state = UUID().uuidString
        return (StravaClient.authorizationURL(
            clientID: credentials.clientID, redirectURI: Self.stravaRedirectURI, state: state
        ), state)
    }

    /// Finishes connecting from the URL the browser was redirected to.
    ///
    /// Checks `state` against the one sent, so a stray or forged callback can't connect someone
    /// else's account, and checks the granted scope: Strava lets the user untick permissions on
    /// the approval page, and without `activity:write` every upload would fail later with a
    /// confusing 401 instead of now with a clear reason.
    func completeStravaConnection(callback: URL, expectedState: String) async throws {
        let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let query = Dictionary(items.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { a, _ in a })
        if let error = query["error"] {
            throw StravaError.authorizationRejected(error == "access_denied" ? "access was declined" : error)
        }
        guard query["state"] == expectedState else {
            throw StravaError.authorizationRejected("the reply didn't match the request")
        }
        guard query["scope"]?.contains("activity:write") == true else {
            throw StravaError.authorizationRejected(
                "upload permission wasn't granted — leave \"Upload your activities\" ticked")
        }
        // Required too, since the sync check learned to notice deletions. Without it Strava hides
        // "Only You" activities from both the listing and a direct lookup, so a private ride would
        // be indistinguishable from a deleted one and get marked not uploaded.
        guard query["scope"]?.contains("activity:read_all") == true else {
            throw StravaError.authorizationRejected(
                "private-activity access wasn't granted — leave \"View data about your private "
                + "activities\" ticked, so MaxAct can tell a private activity from a deleted one")
        }
        guard let code = query["code"] else {
            throw StravaError.invalidResponse("no authorisation code in the callback")
        }
        try await strava.exchange(code: code)
        await refreshStravaConnection()
        // The library has years of workouts the watch already put on Strava. Find them now, so
        // the first thing the user sees isn't hundreds of rows offering to upload duplicates.
        startStravaCheck()
    }

    /// Looks for every workout in the library on Strava, and marks the ones already there.
    func startStravaCheck() {
        guard isStravaConnected, !items.isEmpty else { return }
        let workouts = items.map(\.workout)
        let linkedBefore = Set(items.filter { $0.stravaActivityID != nil }.map(\.id))
        startJob(.checkingStrava) { [self] in
            do {
                // A quiet flag push or upload resume may be under way; let it finish first.
                await waitForQuietStravaWork()
                // Local edits go first, so the import below sees them as settled rather than
                // overwriting them with Strava's stale value.
                _ = await sendPendingStravaFlags()
                let result = try await markWorkoutsAlreadyOnStrava(workouts)
                // Newly linked workouts may have a route Health Auto Export sent only part of
                // (issue 19); the activity just found has all of it.
                await refreshItems()
                let newlyLinked = items.filter { $0.stravaActivityID != nil && !linkedBefore.contains($0.id) }
                if try await fillIncompleteRoutes(in: newlyLinked) > 0 { await refreshItems() }
                return .checkedStrava(result)
            } catch let error as StravaError {
                return .failed(error.description)
            } catch {
                return .failed(Self.describeStravaError(error))
            }
        }
    }

    /// Lists Strava's activities over the workouts' span, and brings the library into line with
    /// it in both directions: workouts found there are marked synced, and synced workouts whose
    /// activity was **deleted** on Strava go back to "not on Strava". It also mirrors Strava's
    /// commute/trainer flags — the same listing carries them, so they cost nothing extra. One read
    /// request per 200 activities: about a dozen for seven years.
    @discardableResult
    func markWorkoutsAlreadyOnStrava(_ workouts: [Workout]) async throws -> StravaCheckResult {
        guard let earliest = workouts.map(\.start).min(), let latest = workouts.map(\.end).max() else {
            return StravaCheckResult(found: 0, removed: 0)
        }
        // A day's margin either side: a workout near the edge must still see an activity that
        // started a few minutes before it.
        let span = DateInterval(start: earliest.addingTimeInterval(-86_400), end: latest.addingTimeInterval(86_400))
        let activities = try await strava.activities(in: span)

        // Deletions first, so a workout whose activity is gone is free to match another one —
        // say, the same ride re-uploaded by the watch — in the pass below. Absence from the
        // listing only nominates; Strava has to confirm each with a 404 before anything changes.
        // Only workouts inside the *unpadded* range are candidates: they are the ones the listing
        // is certain to have covered.
        let missing = try await store.syncedActivities(
            missingFrom: Set(activities.map(\.id)),
            startingWithin: DateInterval(start: earliest, end: latest)
        )
        let deleted = missing.isEmpty ? [] : try await strava.deletedActivities(among: Array(missing.keys))
        let removed = try await store.markRemovedFromStrava(deleted.compactMap { missing[$0] })
        if removed > 0 { await refreshItems() }

        let onStrava = Set(items.filter { $0.stravaState.isOnStrava }.map(\.id))
        let matches = StravaActivityMatcher.match(
            workouts.filter { !onStrava.contains($0.id) }, against: activities
        )
        let marked = try await store.markAlreadyOnStrava(matches)
        try await store.applyStravaFlags(Dictionary(
            activities.map { ($0.id, $0.flags) }, uniquingKeysWith: { first, _ in first }
        ))
        await refreshItems()
        return StravaCheckResult(found: marked, removed: removed)
    }

    struct StravaCheckResult: Equatable {
        let found: Int
        let removed: Int
    }

    func disconnectStrava() async {
        do {
            if try await !strava.disconnect() {
                // Disconnected here, but the grant may still be live at Strava (issue 46).
                reportFailedChange("Disconnected, but Strava couldn't be told",
                                   StravaNotRevoked())
            }
        } catch {
            reportFailedChange("Couldn't disconnect from Strava", error)
        }
        await refreshStravaConnection()
    }

    /// Uploads the selection, one at a time. Skips anything already on Strava, and anything with
    /// no stored detail — a summary-only file would arrive with no route and no heart rate, which
    /// is worse than not uploading it.
    func startStravaUpload(for items: [WorkoutListItem]) {
        guard isStravaConnected else { return }
        let pending = items.filter { !$0.stravaState.isOnStrava && $0.hasDetail }
        guard !pending.isEmpty else { return }
        startJob(.checkingStrava) { await self.uploadToStrava(pending) }
    }

    /// What the Upload action would do with this selection, for its label and enabled state.
    func stravaUploadCount(_ items: [WorkoutListItem]) -> (ready: Int, needingDetail: Int) {
        let notOnStrava = items.filter { !$0.stravaState.isOnStrava }
        let ready = notOnStrava.filter(\.hasDetail).count
        return (ready, notOnStrava.count - ready)
    }

    func uploadToStrava(_ requested: [WorkoutListItem]) async -> SyncStatus {
        let uploader = StravaUploader(client: strava)
        // A resume of the same in-flight uploads, or a flag push, may be under way.
        await waitForQuietStravaWork()

        // Check first: anything the watch already put on Strava would only come back as a
        // duplicate, after spending a write and a few polls to find that out. If the check itself
        // fails, carry on — Strava's own duplicate detection still stands behind the upload.
        _ = await sendPendingStravaFlags()
        do {
            _ = try await markWorkoutsAlreadyOnStrava(requested.map(\.workout))
        } catch {
            Self.log.error("Strava check before upload failed; uploading anyway: \(String(describing: error), privacy: .public)")
        }
        let alreadyThere = Set(self.items.filter { $0.stravaState.isOnStrava }.map(\.id))
        let items = requested.filter { !alreadyThere.contains($0.id) }
        guard !items.isEmpty else { return .finished(.uploadingToStrava, found: 0) }

        // Not ones already in flight (issue 43): marking those queued hid the upload id that
        // `uploadOne` resumes from, so they were sent again — a duplicate, and a wasted write.
        for item in items where item.stravaState != .uploading { await recordStravaState(.queued, for: item.id) }
        await refreshItems()

        var uploaded = 0
        var unrecorded = 0
        var index = 0
        while index < items.count, !Task.isCancelled {
            let item = items[index]
            syncStatus = .running(.uploadingToStrava, completed: index, total: items.count, found: uploaded)
            do {
                let result = try await uploadOne(item, with: uploader)
                if !(await recordStravaState(result.state, activityID: result.activityID,
                                             uploadID: result.uploadID, for: item.id)) {
                    unrecorded += 1
                }
                if result.state.isOnStrava { uploaded += 1 }
                index += 1
            } catch StravaError.rateLimited(let until) {
                // Not a failure of this workout. Wait visibly, then try the same one again —
                // `uploadOne` resumes rather than re-uploads if it had already been accepted.
                syncStatus = .waiting(.uploadingToStrava, until: until)
                try? await Task.sleep(for: .seconds(max(1, until.timeIntervalSinceNow + 2)))
            } catch let error as StravaError where Self.endsBatch(error) {
                // Nothing else will succeed either; stop, and say why.
                await requeue(items[index...])
                await refreshItems()
                return .failed(error.description)
            } catch {
                // Stopped mid-request: not this workout's failure (issue 38; it was marked
                // "failed: cancelled"). Left as it was — still queued, it goes back to not
                // uploaded below; already accepted, it stays uploading and is resumed later.
                if Task.isCancelled { break }
                await recordStravaState(.failed(reason: Self.describeStravaError(error)), for: item.id)
                index += 1
            }
            await refreshItems()
        }

        if Task.isCancelled { await requeue(items[index...]) }
        await refreshItems()
        if unrecorded > 0 {
            // The uploads happened; MaxAct just can't remember them, so the table is wrong until a
            // Strava check puts it right (issue 40).
            reportFailedChange("Uploaded, but couldn't save the result for \(unrecorded) workout"
                               + (unrecorded == 1 ? "" : "s") + ". Check Strava (⌥⌘U) to put the table right",
                               StoreWriteFailed())
        }
        return .finished(.uploadingToStrava, found: uploaded)
    }

    /// Sends one workout — or, if a previous attempt got as far as an upload id, follows that
    /// instead. Re-uploading an accepted workout would only earn a "duplicate" and spend a write.
    func uploadOne(_ item: WorkoutListItem, with uploader: StravaUploader) async throws -> UploadResult {
        let options = UploadOptions(flags: StravaFlags(tags: item.tags), muted: settings.muteStravaUploads)
        let inFlight: [(id: String, uploadID: Int)]
        do {
            inFlight = try await store.itemsUploadingToStrava()
        } catch {
            // Uploading afresh is still safe — Strava rejects the duplicate — but costs a write.
            Self.log.error("Couldn't read uploads in flight; sending \(item.id, privacy: .public) afresh: \(String(describing: error), privacy: .public)")
            inFlight = []
        }
        if let entry = inFlight.first(where: { $0.id == item.id }) {
            return try await uploader.resume(uploadID: entry.uploadID, workout: item.workout, options: options)
        }
        guard let series = await seriesStore.loadIfAvailable(item.id) else {
            return UploadResult(state: .failed(reason: "No route or heart rate stored — download detail first"),
                                activityID: nil, uploadID: nil, warning: nil)
        }
        let store = store, id = item.id, log = Self.log
        return try await uploader.send(item.workout, series: series, options: options) { uploadID in
            // Persisted before polling starts, so a quit mid-wait resumes instead of re-uploading.
            do {
                try await store.setStravaState(.uploading, uploadID: uploadID, for: id)
            } catch {
                log.error("Couldn't save upload \(uploadID) for \(id, privacy: .public): \(String(describing: error), privacy: .public)")
            }
        }
    }

    /// Uploads a previous run accepted but didn't see finish. Quiet: no banner, because the user
    /// didn't just ask for anything, but every outcome is persisted and visible in the table.
    func resumeStravaUploads() {
        guard !hasResumedUploads, isStravaConnected else { return }
        hasResumedUploads = true
        resumeTask = Task {
            defer { resumeTask = nil }
            let inFlight: [(id: String, uploadID: Int)]
            do {
                inFlight = try await store.itemsUploadingToStrava()
            } catch {
                Self.log.error("Couldn't read uploads to resume (tried again next launch): \(String(describing: error), privacy: .public)")
                return
            }
            guard !inFlight.isEmpty else { return }
            let uploader = StravaUploader(client: strava)
            for entry in inFlight {
                guard let item = items.first(where: { $0.id == entry.id }) else { continue }
                let options = UploadOptions(flags: StravaFlags(tags: item.tags),
                                            muted: settings.muteStravaUploads)
                do {
                    let result = try await uploader.resume(uploadID: entry.uploadID, workout: item.workout,
                                                           options: options)
                    await recordStravaState(result.state, activityID: result.activityID,
                                            uploadID: result.uploadID, for: entry.id)
                } catch {
                    // Still marked uploading, so it's resumed again next launch or with the next batch.
                    Self.log.error("Couldn't resume upload \(entry.uploadID) for \(entry.id, privacy: .public): \(String(describing: error), privacy: .public)")
                }
            }
            await refreshItems()
        }
    }

    /// Saves a workout's Strava state; a failure is logged and reported back (issue 40).
    @discardableResult
    func recordStravaState(_ state: StravaState, activityID: Int? = nil, uploadID: Int? = nil,
                           for workoutID: String) async -> Bool {
        do {
            try await store.setStravaState(state, activityID: activityID, uploadID: uploadID, for: workoutID)
            return true
        } catch {
            Self.log.error("Couldn't save Strava state for \(workoutID, privacy: .public): \(String(describing: error), privacy: .public)")
            return false
        }
    }

    /// Until a quiet flag push or upload resume has finished, so a job doesn't send the same
    /// edit or poll the same upload alongside it.
    func waitForQuietStravaWork() async {
        await flagPushTask?.value
        await resumeTask?.value
    }

    /// A background pass's failure. Shown in the banner unless a job is using it — overwriting a
    /// running job's status hid its Stop button and let a second job start (issue 39) — and
    /// logged either way.
    func reportQuietly(_ message: String) {
        Self.log.error("\(message, privacy: .public)")
        if !syncStatus.isRunning { syncStatus = .failed(message) }
    }

    /// Anything still merely queued goes back to not-uploaded, so a stopped batch doesn't leave
    /// rows claiming to be waiting for something that will never come.
    func requeue(_ items: ArraySlice<WorkoutListItem>) async {
        let current = (try? await store.allItems()) ?? []
        for item in items where current.first(where: { $0.id == item.id })?.stravaState == .queued {
            await recordStravaState(.notUploaded, for: item.id)
        }
    }

    static func endsBatch(_ error: StravaError) -> Bool {
        switch error {
        case .notConfigured, .notAuthorized, .authorizationRejected: true
        case .rateLimited, .http, .invalidResponse: false
        }
    }

    static func describeStravaError(_ error: any Error) -> String {
        if let strava = error as? StravaError { return strava.description }
        if let url = error as? URLError {
            return url.code == .notConnectedToInternet ? "No internet connection" : url.localizedDescription
        }
        return error.localizedDescription
    }

    // MARK: Routes from Strava

    /// Once (with Strava connected): routes Health Auto Export sent only part of — some
    /// interval-style Apple Workout-app recordings, measured 3 of 418 — are replaced by the
    /// linked Strava activity's full track. Reads every linked series (~7 s), off the main actor.
    func fillIncompleteRoutesIfNeeded() async {
        guard !settings.hasFilledIncompleteRoutes, !isFillingRoutes, isStravaConnected, !syncStatus.isRunning else { return }
        isFillingRoutes = true
        defer { isFillingRoutes = false }
        do {
            let filled = try await fillIncompleteRoutes(in: items)
            settings.hasFilledIncompleteRoutes = true
            if filled > 0 { items = (try? await store.allItems()) ?? items }
        } catch {
            // Tried again next launch; said now, since a route stays incomplete until it works.
            reportQuietly("Couldn't fill incomplete routes from Strava: \(Self.describeStravaError(error)). "
                          + "MaxAct will try again next time it opens.")
        }
    }

    /// Replaces each of `candidates`' stored routes that covers under half its workout with the
    /// linked Strava activity's track, when that's longer. Returns how many were replaced.
    @discardableResult
    func fillIncompleteRoutes(in candidates: [WorkoutListItem]) async throws -> Int {
        var filled = 0
        for item in candidates {
            guard let activityID = item.stravaActivityID,
                  let series = await seriesStore.loadIfAvailable(item.id),
                  series.routeIsIncomplete(duration: item.workout.duration)
            else { continue }
            let route = try await strava.route(ofActivity: activityID)
            guard let last = route.last, let first = route.first,
                  last.timestamp.timeIntervalSince(first.timestamp) > series.routeSpan
            else { continue }
            try await seriesStore.save(series.replacingRoute(route, fromStravaActivity: activityID))
            await routeSketchCache?.invalidate([item.id])
            thumbnails.delete(workoutID: item.id)
            filled += 1
        }
        return filled
    }
}

/// The store refused a write; the underlying errors are in the log.
struct StoreWriteFailed: LocalizedError {
    var errorDescription: String? { "the library couldn't be written" }
}

/// Strava didn't confirm revoking MaxAct's access.
struct StravaNotRevoked: LocalizedError {
    var errorDescription: String? { "revoke MaxAct's access at strava.com/settings/apps" }
}
