import Foundation
import Observation
import MaxActCore
import SwiftUI

/// Application state for the browsing UI.
///
/// `@MainActor` and `@Observable`: the table binds to `visibleItems` and `selection` directly.
/// The stores it talks to are actors, so every mutation here is an `await` that hops off and back.
@MainActor
@Observable
final class AppModel {
    // MARK: Data

    private(set) var items: [WorkoutListItem] = []
    private(set) var isLoading = false
    private(set) var loadError: String?

    // MARK: View state

    var sidebarSelection: SidebarSelection? = .filter(.all)
    var searchText = ""
    var selection: Set<String> = []
    var sortOrder: [KeyPathComparator<WorkoutListItem>] = [
        KeyPathComparator(\.workout.start, order: .reverse)
    ]

    /// Whether the sync popover is showing. Held here rather than in the view so the menu-bar
    /// command can open it directly — it used to go through a `NotificationCenter` hop, which was
    /// indirection with no benefit and one more thing that could silently not fire.
    var isSyncPanelPresented = false

    // MARK: Sync

    private(set) var syncStatus: SyncStatus = .idle

    /// Which job the progress refers to. Without this the banner said "Syncing week 3 of 8"
    /// during a detail backfill, which counts workouts rather than weeks.
    enum SyncActivity: Equatable {
        case listing
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
        case failed(String)

        var isRunning: Bool {
            switch self {
            case .running, .waiting: true
            case .idle, .finished, .failed: false
            }
        }

        var message: String? {
            switch self {
            case .idle:
                nil
            case .running(.listing, let done, let total, let found):
                "Syncing week \(done + 1) of \(total) — \(found) workouts so far"
            case .running(.fillingDetail, let done, let total, _):
                "Downloading detail — \(done) of \(total)"
            case .finished(.listing, let found):
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
            case .waiting(_, let until):
                "Paused for Strava's rate limit — resumes at "
                    + until.formatted(date: .omitted, time: .shortened)
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

    // MARK: Dependencies

    let store: WorkoutStore
    let seriesStore: SeriesStore
    let thumbnails: RouteThumbnailRenderer
    let settings: AppSettings

    /// Number of synthetic workouts to plant on first load, for UI tests and previews. `nil` in
    /// normal use.
    let seedCount: Int?

    /// Whether to reverse-geocode place names. Off under UI testing: it is a network call, and a
    /// test suite that depends on Apple's geocoder is a test suite that fails on a train.
    let resolvesPlaces: Bool

    private var syncTask: Task<Void, Never>?
    private var hasSeeded = false

    // MARK: Strava

    /// Where the Strava application credentials and tokens live. A separate Keychain service
    /// under UI testing, so a test can never sign the real account out.
    let stravaSecrets: KeychainSecretStore
    let strava: StravaClient

    /// Whether a client ID and secret have been entered, and whose account is connected.
    private(set) var isStravaConfigured = false
    private(set) var stravaAthlete: String?
    var isStravaConnected: Bool { stravaAthlete != nil }
    private var hasResumedUploads = false

    /// The redirect Strava sends the browser back to. Strava only checks the *host* against the
    /// app's "Authorization Callback Domain", so that has to be set to `localhost` on
    /// strava.com/settings/api; the scheme is what hands control back to us.
    static let stravaRedirectURI = "maxact://localhost/strava"
    static let stravaCallbackScheme = "maxact"

    /// Resolves coarse coordinates into place names. One instance for the app's lifetime, so its
    /// cache of cell → name survives across loads and syncs.
    @ObservationIgnored private let placeResolver: PlaceResolver
    private var placeTask: Task<Void, Never>?

    init(
        store: WorkoutStore,
        seriesStore: SeriesStore,
        thumbnails: RouteThumbnailRenderer,
        settings: AppSettings,
        seedCount: Int? = nil,
        resolvesPlaces: Bool = true,
        stravaSecrets: KeychainSecretStore = KeychainSecretStore()
    ) {
        self.stravaSecrets = stravaSecrets
        strava = StravaClient(secrets: stravaSecrets)
        self.store = store
        self.seriesStore = seriesStore
        self.thumbnails = thumbnails
        self.settings = settings
        self.seedCount = seedCount
        self.resolvesPlaces = resolvesPlaces
        placeResolver = PlaceResolver(store: store)
    }

    /// Used when the on-disk stores can't be opened. Everything works; nothing persists.
    static func inMemoryFallback(
        settings: AppSettings, seedCount: Int? = nil, resolvesPlaces: Bool = true,
        stravaSecrets: KeychainSecretStore = KeychainSecretStore()
    ) -> AppModel {
        // Force-unwrapped deliberately: an in-memory container and a temp directory failing
        // would mean the process cannot allocate or write anywhere, and there is no recovery.
        removeStaleScratchDirectories()
        let scratch = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "\(scratchPrefix)\(UUID().uuidString)")
        let seriesStore = try! SeriesStore(directory: scratch.appending(path: "Series"))
        return AppModel(
            store: WorkoutStore(modelContainer: try! WorkoutStore.container(inMemory: true)),
            seriesStore: seriesStore,
            // Thumbnails go to scratch as well. Without this, UI tests wrote into — and a
            // delete-all test would have wiped — the user's real thumbnail cache.
            thumbnails: try! RouteThumbnailRenderer(
                seriesStore: seriesStore, directory: scratch.appending(path: "Thumbnails")
            ),
            settings: settings,
            seedCount: seedCount,
            resolvesPlaces: resolvesPlaces,
            stravaSecrets: stravaSecrets
        )
    }

    private static let scratchPrefix = "MaxActFallback-"

    /// Deletes scratch directories left behind by earlier in-memory launches.
    ///
    /// Every UI test launches with an in-memory store and its own scratch directory, and XCUITest
    /// ends each test by *killing* the app — so cleanup at quit never runs, and ~350 of these had
    /// piled up in the container's `tmp/`. Sweeping at the next launch is the one point that is
    /// guaranteed to happen. Only directories untouched for an hour go, so a concurrently running
    /// instance can never have its live store deleted from under it.
    private static func removeStaleScratchDirectories(olderThan age: TimeInterval = 3600) {
        let fileManager = FileManager.default
        let temporary = URL(fileURLWithPath: NSTemporaryDirectory())
        let cutoff = Date.now.addingTimeInterval(-age)
        let entries = (try? fileManager.contentsOfDirectory(
            at: temporary, includingPropertiesForKeys: [.contentModificationDateKey]
        )) ?? []
        for entry in entries where entry.lastPathComponent.hasPrefix(scratchPrefix) {
            let modified = (try? entry.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            if modified < cutoff { try? fileManager.removeItem(at: entry) }
        }
    }

    // MARK: Derived

    /// Rows after the sidebar filter, the search field and the column sort.
    ///
    /// Recomputed on read rather than cached. At a few thousand value-type rows this is well
    /// inside a frame, and caching it would mean invalidating on five different inputs — a
    /// reliable source of stale-list bugs for no measured gain.
    var visibleItems: [WorkoutListItem] {
        var result = items
        if let sidebarSelection {
            result = result.filter(sidebarSelection.matches)
        }
        if !searchText.isEmpty {
            result = result.filter { $0.matches(searchText: searchText) }
        }
        return result.sorted(using: sortOrder)
    }

    var selectedItems: [WorkoutListItem] {
        // Preserve the table's visible order, so the summary reads the way the list looks.
        visibleItems.filter { selection.contains($0.id) }
    }

    var selectedAggregate: WorkoutAggregate {
        WorkoutAggregate(selectedItems.map(\.workout))
    }

    /// Activity kinds actually present, for the sidebar. Sorted by frequency then name, so the
    /// sports someone actually does are at the top.
    var presentKinds: [(key: String, kind: ActivityKind, count: Int)] {
        Dictionary(grouping: items, by: { $0.workout.kind.storageKey })
            .map { (key: $0.key, kind: ActivityKind(storageKey: $0.key), count: $0.value.count) }
            .sorted { ($0.count, $1.kind.displayName) > ($1.count, $0.kind.displayName) }
    }

    func count(for selection: SidebarSelection) -> Int {
        items.count(where: selection.matches)
    }

    /// Workouts still missing their route and second-resolution series, newest first.
    ///
    /// Newest first because those are the ones most likely to be opened, and because a backfill
    /// of several thousand is going to be interrupted — whatever arrives first should be the
    /// part that gets used.
    func backlog(_ scope: BackfillScope) -> [WorkoutListItem] {
        let pool = scope == .everything ? items : visibleItems
        return pool
            .filter { !$0.hasDetail }
            .sorted { $0.workout.start > $1.workout.start }
    }

    func backlogCount(_ scope: BackfillScope) -> Int {
        let pool = scope == .everything ? items : visibleItems
        return pool.count { !$0.hasDetail }
    }

    // MARK: Actions

    func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            try await seedIfRequested()
            items = try await store.allItems()
            loadError = nil
        } catch {
            loadError = "Could not load workouts: \(error.localizedDescription)"
        }
        resolvePlaces()
        await refreshStravaConnection()
        resumeStravaUploads()
    }

    // MARK: Strava

    /// Re-reads what the Keychain holds, for the Settings pane and for enabling Upload.
    func refreshStravaConnection() async {
        let credentials = await stravaSecrets.credentials()
        isStravaConfigured = credentials?.isComplete ?? false
        let tokens = await stravaSecrets.tokens()
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
        guard !syncStatus.isRunning, isStravaConnected, !items.isEmpty else { return }
        let workouts = items.filter { !$0.stravaState.isOnStrava }.map(\.workout)
        syncTask = Task {
            syncStatus = .running(.checkingStrava, completed: 0, total: 1, found: 0)
            do {
                let found = try await markWorkoutsAlreadyOnStrava(workouts)
                syncStatus = .finished(.checkingStrava, found: found)
            } catch let error as StravaError {
                syncStatus = .failed(error.description)
            } catch {
                syncStatus = .failed(Self.describeUpload(error))
            }
        }
    }

    /// Lists Strava's activities over the workouts' span and marks the matches. Costs one read
    /// request per 200 activities in the span — about a dozen for seven years.
    @discardableResult
    private func markWorkoutsAlreadyOnStrava(_ workouts: [Workout]) async throws -> Int {
        guard let earliest = workouts.map(\.start).min(), let latest = workouts.map(\.end).max() else { return 0 }
        // A day's margin either side: a workout near the edge must still see an activity that
        // started a few minutes before it.
        let span = DateInterval(start: earliest.addingTimeInterval(-86_400), end: latest.addingTimeInterval(86_400))
        let activities = try await strava.activities(in: span)
        let matches = StravaActivityMatcher.match(workouts, against: activities)
        let marked = try await store.markAlreadyOnStrava(matches)
        await refreshItems()
        return marked
    }

    func disconnectStrava() async {
        try? await strava.disconnect()
        await refreshStravaConnection()
    }

    /// Uploads the selection, one at a time. Skips anything already on Strava, and anything with
    /// no stored detail — a summary-only file would arrive with no route and no heart rate, which
    /// is worse than not uploading it.
    func startStravaUpload(for items: [WorkoutListItem]) {
        guard !syncStatus.isRunning, isStravaConnected else { return }
        let pending = items.filter { !$0.stravaState.isOnStrava && $0.hasDetail }
        guard !pending.isEmpty else { return }
        syncTask = Task { await uploadToStrava(pending) }
    }

    /// What the Upload action would do with this selection, for its label and enabled state.
    func stravaUploadCount(_ items: [WorkoutListItem]) -> (ready: Int, needingDetail: Int) {
        let notOnStrava = items.filter { !$0.stravaState.isOnStrava }
        let ready = notOnStrava.filter(\.hasDetail).count
        return (ready, notOnStrava.count - ready)
    }

    private func uploadToStrava(_ requested: [WorkoutListItem]) async {
        let uploader = StravaUploader(client: strava)

        // Check first: anything the watch already put on Strava would only come back as a
        // duplicate, after spending a write and a few polls to find that out. If the check itself
        // fails, carry on — Strava's own duplicate detection still stands behind the upload.
        syncStatus = .running(.checkingStrava, completed: 0, total: 1, found: 0)
        _ = try? await markWorkoutsAlreadyOnStrava(requested.map(\.workout))
        let alreadyThere = Set(self.items.filter { $0.stravaState.isOnStrava }.map(\.id))
        let items = requested.filter { !alreadyThere.contains($0.id) }
        guard !items.isEmpty else {
            syncStatus = .finished(.uploadingToStrava, found: 0)
            return
        }

        for item in items { try? await store.setStravaState(.queued, for: item.id) }
        await refreshItems()

        var uploaded = 0
        var index = 0
        while index < items.count, !Task.isCancelled {
            let item = items[index]
            syncStatus = .running(.uploadingToStrava, completed: index, total: items.count, found: uploaded)
            do {
                let result = try await uploadOne(item, with: uploader)
                try? await store.setStravaState(
                    result.state, activityID: result.activityID, uploadID: result.uploadID, for: item.id
                )
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
                syncStatus = .failed(error.description)
                await refreshItems()
                return
            } catch {
                try? await store.setStravaState(.failed(reason: Self.describeUpload(error)), for: item.id)
                index += 1
            }
            await refreshItems()
        }

        if Task.isCancelled { await requeue(items[index...]) }
        await refreshItems()
        syncStatus = .finished(.uploadingToStrava, found: uploaded)
    }

    /// Sends one workout — or, if a previous attempt got as far as an upload id, follows that
    /// instead. Re-uploading an accepted workout would only earn a "duplicate" and spend a write.
    private func uploadOne(_ item: WorkoutListItem, with uploader: StravaUploader) async throws -> UploadResult {
        if let inFlight = try? await store.itemsUploadingToStrava().first(where: { $0.id == item.id }) {
            return try await uploader.resume(uploadID: inFlight.uploadID, workout: item.workout)
        }
        guard let series = await seriesStore.loadIfAvailable(item.id) else {
            return UploadResult(state: .failed(reason: "No route or heart rate stored — download detail first"),
                                activityID: nil, uploadID: nil, warning: nil)
        }
        let store = store
        let id = item.id
        return try await uploader.send(item.workout, series: series) { uploadID in
            // Persisted before polling starts, so a quit mid-wait resumes instead of re-uploading.
            try? await store.setStravaState(.uploading, uploadID: uploadID, for: id)
        }
    }

    /// Uploads a previous run accepted but didn't see finish. Quiet: no banner, because the user
    /// didn't just ask for anything, but every outcome is persisted and visible in the table.
    private func resumeStravaUploads() {
        guard !hasResumedUploads, isStravaConnected else { return }
        hasResumedUploads = true
        Task {
            guard let inFlight = try? await store.itemsUploadingToStrava(), !inFlight.isEmpty else { return }
            let uploader = StravaUploader(client: strava)
            for entry in inFlight {
                guard let item = items.first(where: { $0.id == entry.id }) else { continue }
                if let result = try? await uploader.resume(uploadID: entry.uploadID, workout: item.workout) {
                    try? await store.setStravaState(
                        result.state, activityID: result.activityID, uploadID: result.uploadID, for: entry.id
                    )
                }
            }
            await refreshItems()
        }
    }

    /// Anything still merely queued goes back to not-uploaded, so a stopped batch doesn't leave
    /// rows claiming to be waiting for something that will never come.
    private func requeue(_ items: ArraySlice<WorkoutListItem>) async {
        let current = (try? await store.allItems()) ?? []
        for item in items where current.first(where: { $0.id == item.id })?.stravaState == .queued {
            try? await store.setStravaState(.notUploaded, for: item.id)
        }
    }

    private static func endsBatch(_ error: StravaError) -> Bool {
        switch error {
        case .notConfigured, .notAuthorized, .authorizationRejected: true
        case .rateLimited, .http, .invalidResponse: false
        }
    }

    private static func describeUpload(_ error: any Error) -> String {
        if let strava = error as? StravaError { return strava.description }
        if let url = error as? URLError {
            return url.code == .notConnectedToInternet ? "No internet connection" : url.localizedDescription
        }
        return error.localizedDescription
    }

    /// Cheaper than `load()`: no place resolution, no Strava resume.
    private func refreshItems() async {
        if let fresh = try? await store.allItems() { items = fresh }
    }

    /// Fills in the Place column in the background.
    ///
    /// Deliberately not awaited by `load()`: on a first import this walks every distinct place at
    /// one request per second, and the table must be usable long before it finishes. Failures are
    /// silent by design — an empty Place cell is a cosmetic gap, not something worth an error
    /// banner over a table that otherwise works.
    private func resolvePlaces() {
        guard resolvesPlaces, placeTask == nil else { return }
        placeTask = Task {
            // Workouts synced before Phase 6 have a route on disk but no snapped start, so they
            // would never appear in the pending query without this.
            _ = try? await store.backfillPlaceCoordinates(seriesStore: seriesStore)

            let stored = await placeResolver.resolvePending()
            if stored > 0, !Task.isCancelled {
                items = (try? await store.allItems()) ?? items
            }
            placeTask = nil
        }
    }

    /// Plants synthetic data on the first load when `--ui-testing-seed` was passed.
    ///
    /// Done here rather than in `init` because seeding is async, and before the fetch so the
    /// first frame the tests see is already populated — a test that races the seed is worse than
    /// no test.
    private func seedIfRequested() async throws {
        guard let seedCount, !hasSeeded else { return }
        hasSeeded = true
        try await store.upsert(
            SampleData.ingested(count: seedCount), seriesStore: seriesStore
        )
    }

    // Selecting everything is deliberately *not* here: Edit ▸ Select All is standard and SwiftUI
    // already routes it to the table's selection binding. Deselecting has no system equivalent.
    func clearSelection() {
        selection.removeAll()
    }

    // MARK: Sync

    /// Runs the list pass over a span, newest week first, writing each chunk as it lands.
    ///
    /// Chunks are committed individually rather than batched at the end: a sync that is
    /// interrupted — which is likely, since it needs HAE foregrounded for the duration — keeps
    /// everything it had already fetched.
    func sync(source: HAEWorkoutSource, from start: Date, to end: Date = .now) async {
        guard !syncStatus.isRunning else { return }
        let windows = SyncPlanner.windowsNewestFirst(from: start, to: end)
        syncStatus = .running(.listing, completed: 0, total: windows.count, found: 0)

        do {
            try await source.connect()
            var found = 0
            for (index, window) in windows.enumerated() {
                if Task.isCancelled { break }
                let result = try await source.listWorkouts(in: window)
                try await store.upsert(result.workouts)
                found += result.workouts.count
                syncStatus = .running(.listing, completed: index + 1, total: windows.count, found: found)
                await load()
            }
            syncStatus = .finished(.listing, found: found)
        } catch {
            // Partial progress is kept: every completed chunk is already committed.
            syncStatus = .failed(Self.describe(error))
        }
    }

    /// Fetches routes and second-resolution series for specific workouts.
    func fetchDetail(for workouts: [WorkoutListItem], source: HAEWorkoutSource) async {
        guard !syncStatus.isRunning else { return }
        let pending = workouts.filter { !$0.hasDetail }
        syncStatus = .running(.fillingDetail, completed: 0, total: pending.count, found: 0)
        do {
            try await source.connect()
            var fetched = 0
            for (index, item) in pending.enumerated() {
                if Task.isCancelled { break }
                if let detail = try await source.fetchDetail(for: item.workout) {
                    try await store.upsert([detail], seriesStore: seriesStore)
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
            syncStatus = .finished(.fillingDetail, found: fetched)
        } catch {
            await load()
            syncStatus = .failed(Self.describe(error))
        }
    }

    func dismissSyncStatus() {
        syncStatus = .idle
    }

    // MARK: Stored data

    /// Bytes held by series blobs and thumbnails. The database itself is small by comparison —
    /// it holds only the denormalised summary rows.
    func storageBytes() async -> Int {
        let series = (try? await seriesStore.totalBytes()) ?? 0
        return series + thumbnails.totalBytes()
    }

    /// Deletes every workout, series blob and thumbnail.
    ///
    /// Does **not** touch the server address or token — those are settings, not data, and having
    /// to retype them to clear a test corpus would be a nuisance. Nothing here is irreplaceable:
    /// everything can be re-synced from the phone, which is the point of making it easy.
    ///
    /// Series and thumbnails must go along with the rows. Both are keyed on the HealthKit UUID,
    /// so leaving them behind would let a later re-sync silently adopt the orphaned blobs of
    /// deleted workouts.
    func deleteAllData() async {
        do {
            try await store.deleteAll()
            try await seriesStore.deleteAll()
            try thumbnails.deleteAll()
            selection.removeAll()
            hasSeeded = true   // don't re-seed a store the user just asked to empty
            await load()
            syncStatus = .idle
        } catch {
            loadError = "Could not delete data: \(error.localizedDescription)"
        }
    }

    // MARK: Task lifecycle

    /// Starts a list-pass sync back to `start`.
    ///
    /// The span is a parameter rather than a stored preference: it's a per-sync decision, since a
    /// daily top-up wants a week and the initial import wants everything.
    func startSync(from start: Date) {
        guard let source = settings.makeSource(), !syncStatus.isRunning else { return }
        syncTask = Task { await sync(source: source, from: start) }
    }

    /// Walks the whole backlog for a scope, newest first.
    func startDetailBackfill(scope: BackfillScope) {
        startDetailFetch(for: backlog(scope))
    }

    func startDetailFetch(for items: [WorkoutListItem]) {
        guard let source = settings.makeSource(), !syncStatus.isRunning else { return }
        syncTask = Task { await fetchDetail(for: items, source: source) }
    }

    /// Cancellation is cooperative and safe at any point: each completed weekly chunk has already
    /// been committed, so stopping loses at most the chunk in flight.
    func cancelSync() {
        syncTask?.cancel()
        syncTask = nil
        if syncStatus.isRunning { syncStatus = .idle }
    }

    /// Network failures here almost always mean one thing, so say that rather than surfacing
    /// "Could not connect to the server", which sends people looking at their Mac.
    private static func describe(_ error: any Error) -> String {
        if let mcp = error as? MCPError {
            switch mcp {
            case .http(401, _), .http(403, _):
                return "Health Auto Export rejected the token. Re-read it from the Server screen."
            default:
                return mcp.description
            }
        }
        let message = error.localizedDescription
        if (error as NSError).domain == NSURLErrorDomain {
            return "Can't reach Health Auto Export. Open it on your iPhone, start the server, "
                 + "and keep the app in the foreground. (\(message))"
        }
        return message
    }
}
