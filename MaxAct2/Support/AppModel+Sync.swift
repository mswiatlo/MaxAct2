import Foundation
import MaxActCore
import os

/// Syncing from Health Auto Export, and the one job at a time that every sync, download and
/// Strava batch runs as. Split out of `AppModel.swift` (issue 39).
extension AppModel {
    /// Which job the progress refers to. Without this the banner said "Syncing week 3 of 8"
    /// during a detail backfill, which counts workouts rather than weeks.
    enum SyncActivity: Equatable {
        case listing
        /// "Everything" (issue 24): a list pass with no fixed start, reporting how far back it has
        /// reached rather than "week n of m".
        case listingEverything(reachedBack: Date)
        case fillingDetail
        case uploadingToStrava
        case checkingStrava
    }

    enum SyncStatus: Equatable {
        case idle
        case running(SyncActivity, completed: Int, total: Int, found: Int)
        case finished(SyncActivity, found: Int)
        /// Paused for Strava's rate limit, still running. Distinct from a failure: the batch
        /// resumes on its own at `until`, and the user should see when rather than a spinner.
        case waiting(SyncActivity, until: Date)
        /// The sync-status check, which reports two counts rather than one.
        case checkedStrava(StravaCheckResult)
        /// A list sync that ran to the end: how many workouts arrived, and how many of those
        /// couldn't be read. Its own case because both "nothing arrived" and "some couldn't be
        /// read" are worth a warning rather than a quiet success.
        case listed(found: Int, unreadable: Int)
        case failed(String)

        /// "Found 2 workouts already on Strava · 1 was deleted there", or either half alone.
        static func describe(_ result: StravaCheckResult) -> String {
            var parts: [String] = []
            if result.found > 0 {
                parts.append("Found \(result.found) workout\(result.found == 1 ? "" : "s") already on Strava")
            }
            if result.removed > 0 {
                parts.append(result.removed == 1
                             ? "1 was deleted on Strava and is marked not uploaded"
                             : "\(result.removed) were deleted on Strava and are marked not uploaded")
            }
            return parts.isEmpty ? "Nothing new found on Strava" : parts.joined(separator: " · ")
        }

        var isRunning: Bool {
            switch self {
            case .running, .waiting: true
            case .idle, .finished, .checkedStrava, .listed, .failed: false
            }
        }

        /// Finished, but with something the user should look at.
        var isWarning: Bool {
            if case .listed(let found, let unreadable) = self { return found == 0 || unreadable > 0 }
            return false
        }

        var message: String? {
            switch self {
            case .idle:
                nil
            case .running(.listing, let done, let total, let found):
                "Syncing week \(done + 1) of \(total) — \(found) workouts so far"
            case .running(.listingEverything(let reachedBack), _, _, let found):
                "Syncing everything — back to \(reachedBack.formatted(.dateTime.month(.wide).year())) — \(found) workouts so far"
            case .running(.fillingDetail, let done, let total, _):
                "Downloading detail — \(done) of \(total)"
            case .finished(.listing, let found), .finished(.listingEverything, let found):
                found == 0 ? "No new workouts" : "Synced \(found) workouts"
            case .finished(.fillingDetail, let found):
                found == 0 ? "Nothing left to download" : "Downloaded detail for \(found) workouts"
            case .running(.uploadingToStrava, let done, let total, _):
                "Uploading to Strava — \(done) of \(total)"
            case .finished(.uploadingToStrava, let found):
                found == 0 ? "Nothing was uploaded" : "Uploaded \(found) workouts to Strava"
            case .running(.checkingStrava, _, _, _):
                "Checking Strava for workouts already there…"
            case .finished(.checkingStrava, let found):
                found == 0 ? "Nothing new found on Strava"
                    : "Found \(found) workout\(found == 1 ? "" : "s") already on Strava"
            case .checkedStrava(let result):
                Self.describe(result)
            case .waiting(_, let until):
                "Paused for Strava's rate limit — resumes at "
                    + until.formatted(date: .omitted, time: .shortened)
            case .listed(0, 0):
                SyncProblem.nothingReturned.message
            case .listed(0, let unreadable):
                "None of the \(unreadable) workouts Health Auto Export sent could be read. It may be "
                    + "a newer version than MaxAct knows."
            case .listed(let found, 0):
                "Synced \(found) workouts"
            case .listed(let found, let unreadable):
                "Synced \(found) workouts · \(unreadable) couldn't be read and were skipped"
            case .failed(let reason):
                reason
            }
        }
    }

    /// What a detail backfill should cover.
    enum BackfillScope: Hashable, CaseIterable, Identifiable {
        /// Everything in the library.
        case everything
        /// Only what the sidebar filter and search currently show.
        case visible

        var id: Self { self }
    }

    // MARK: Sync

    /// Runs the list pass over a span, newest week first, writing each chunk as it lands.
    ///
    /// Chunks are committed individually rather than batched at the end: a sync that is
    /// interrupted — which is likely, since it needs HAE foregrounded for the duration — keeps
    /// everything it had already fetched.
    func sync(source: HAEWorkoutSource, from start: Date, to end: Date = .now) async {
        let windows = SyncPlanner.windowsNewestFirst(from: start, to: end)
        await startJob(.listing, total: windows.count) {
            await self.listWeeks(windows, source: source) { _ in .listing }
        }?.value
    }

    /// "Everything" (issue 24): the list pass back to `SyncPlanner.everythingStart`, weekly and
    /// newest first like any sync, reporting how far back it has reached rather than "week n of
    /// m" with a time estimate — most of those weeks are empty and nearly free, so a count of
    /// weeks says nothing about the time left.
    func syncEverything(source: HAEWorkoutSource, end: Date = .now) async {
        let windows = SyncPlanner.windowsNewestFirst(from: SyncPlanner.everythingStart, to: end)
        await startJob(.listingEverything(reachedBack: end), total: windows.count) {
            await self.listWeeks(windows, source: source) { .listingEverything(reachedBack: $0.start) }
        }?.value
    }

    /// The list pass's walk, shared by both syncs. The table is reloaded only after weeks that
    /// brought something — most of an "Everything" walk is empty weeks — and once at the end.
    func listWeeks(
        _ windows: [SyncWindow], source: HAEWorkoutSource,
        activity: (SyncWindow) -> SyncActivity
    ) async -> SyncStatus {
        var found = 0, unreadable = 0
        do {
            try await source.connect()
            for (index, window) in windows.enumerated() {
                if Task.isCancelled { break }
                let result = try await source.listWorkouts(in: window)
                try await store.upsert(result.workouts)
                found += result.workouts.count
                // Counted and logged rather than dropped: these used to vanish without a trace.
                unreadable += result.failures.count
                for failure in result.failures {
                    Self.log.error("Unreadable workout \(failure.workoutID ?? "?", privacy: .public): \(String(describing: failure.underlying), privacy: .public)")
                }
                syncStatus = .running(activity(window), completed: index + 1, total: windows.count, found: found)
                if !result.workouts.isEmpty { await load() }
            }
            await load()
            return .listed(found: found, unreadable: unreadable)
        } catch {
            // Partial progress is kept: every completed week is already committed.
            await load()
            return .failed(Self.describe(error))
        }
    }

    /// Fetches routes and second-resolution series for specific workouts.
    func fetchDetail(for workouts: [WorkoutListItem], source: HAEWorkoutSource) async {
        let pending = workouts.filter { !$0.hasDetail }
        await startJob(.fillingDetail, total: pending.count) {
            await self.downloadDetail(pending, source: source)
        }?.value
    }

    func downloadDetail(_ pending: [WorkoutListItem], source: HAEWorkoutSource) async -> SyncStatus {
        do {
            try await source.connect()
            var fetched = 0
            for (index, item) in pending.enumerated() {
                if Task.isCancelled { break }
                if let detail = try await source.fetchDetail(for: item.workout) {
                    try await store.upsert([detail], seriesStore: seriesStore)
                    // A re-download replaces the series; its cached digest would be stale.
                    await routeSketchCache?.invalidate([item.id])
                    // A partial route comes back with every re-download; refill it from Strava.
                    if isStravaConnected, detail.series.routeIsIncomplete(duration: item.workout.duration) {
                        do {
                            _ = try await fillIncompleteRoutes(in: [item])
                        } catch {
                            // The inspector still says the route is incomplete; the log says why.
                            Self.log.error("Couldn't fill \(item.id, privacy: .public)'s route from Strava: \(String(describing: error), privacy: .public)")
                        }
                    }
                    fetched += 1
                }
                syncStatus = .running(
                    .fillingDetail, completed: index + 1, total: pending.count, found: fetched
                )
                // Refresh periodically rather than only at the end: a long backfill should fill
                // the table in visibly, and an interruption keeps whatever already landed.
                if index.isMultiple(of: 5) { await load() }
            }
            await load()
            return .finished(.fillingDetail, found: fetched)
        } catch {
            await load()
            return .failed(Self.describe(error))
        }
    }

    // MARK: Jobs

    /// Starts a list-pass sync of `start`…`end` — by default back from now.
    ///
    /// The span is a parameter rather than a stored preference: it's a per-sync decision, since a
    /// daily top-up wants a week, the initial import wants everything, and a single past month
    /// (issue 17) wants neither.
    func startSync(from start: Date, to end: Date = .now, source: HAEWorkoutSource? = nil) {
        guard let source = source ?? settings.makeSource() else { return }
        let windows = SyncPlanner.windowsNewestFirst(from: start, to: end)
        startJob(.listing, total: windows.count) {
            await self.listWeeks(windows, source: source) { _ in .listing }
        }
    }

    func startSyncEverything() {
        guard let source = settings.makeSource() else { return }
        let end = Date.now
        let windows = SyncPlanner.windowsNewestFirst(from: SyncPlanner.everythingStart, to: end)
        startJob(.listingEverything(reachedBack: end), total: windows.count) {
            await self.listWeeks(windows, source: source) { .listingEverything(reachedBack: $0.start) }
        }
    }

    /// Walks the whole backlog for a scope, newest first.
    func startDetailBackfill(scope: BackfillScope) {
        startDetailFetch(for: backlog(scope))
    }

    func startDetailFetch(for items: [WorkoutListItem]) {
        guard let source = settings.makeSource() else { return }
        let pending = items.filter { !$0.hasDetail }
        startJob(.fillingDetail, total: pending.count) { await self.downloadDetail(pending, source: source) }
    }

    /// Starts `work` as the job, unless one is already running; returns its task, or `nil` if
    /// refused (issue 39).
    ///
    /// The status is set **before** returning, so a second call in the same turn — a double
    /// click, or the Strava connection starting a check while the menu fires — is refused rather
    /// than starting a second job. The job's own result becomes the status when it ends, unless
    /// it was stopped: then it ends idle, not with a "Synced N" that appears after Stop.
    @discardableResult
    func startJob(_ activity: SyncActivity, total: Int = 1,
                  _ work: @escaping () async -> SyncStatus) -> Task<Void, Never>? {
        guard job == nil, !syncStatus.isRunning else { return nil }
        syncStatus = .running(activity, completed: 0, total: total, found: 0)
        let task = Task {
            let outcome = await work()
            syncStatus = Task.isCancelled ? .idle : outcome
            job = nil
            isStopping = false
        }
        job = task
        return task
    }

    /// Asks the job to stop. Cancellation is cooperative: the job finishes what it has in flight
    /// — each completed weekly chunk is already committed, so at most that chunk is lost — and
    /// stays running (the banner says "Stopping…") until it has, so nothing new can start
    /// alongside it. Health Auto Export serves one client at a time.
    func cancelSync() {
        guard let job, !isStopping else { return }
        isStopping = true
        job.cancel()
    }

    /// Until the current job, if any, has ended. For tests.
    func waitForJob() async {
        await job?.value
    }

    /// A Health Auto Export failure in terms the user can act on — see `SyncProblem`, which tells
    /// "the server isn't running" from "the phone can't be reached" from "the token was rejected".
    static func describe(_ error: any Error) -> String {
        SyncProblem(error: error).message
    }
}
