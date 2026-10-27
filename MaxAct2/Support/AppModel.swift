import Foundation
import os
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

    /// Written here and by the passes in the `AppModel+` extensions.
    var items: [WorkoutListItem] = []
    private(set) var isLoading = false
    /// A failure loading or changing the library, shown in a banner until dismissed.
    private(set) var loadError: String?

    // MARK: View state

    /// Remembered between launches, as is `sortOrder` (Phase 8); restored in `init`. The search
    /// and the selection are deliberately not — a relaunch starts with a clean slate there.
    var sidebarSelection: SidebarSelection? = .filter(.all) {
        didSet {
            settings.sidebarSelectionKey = sidebarSelection?.storageKey
            noteRowChange()
        }
    }
    var searchText = "" {
        didSet { noteRowChange() }
    }
    var selection: Set<String> = []
    var sortOrder: [KeyPathComparator<WorkoutListItem>] = TableSort.default {
        didSet { settings.tableSortKey = TableSort.storageKey(for: sortOrder) }
    }

    /// Whether a restored sidebar choice has been checked against the loaded library yet.
    private var hasCheckedRestoredSelection = false

    /// Whether the sync popover is showing. Held here rather than in the view so the menu-bar
    /// command can open it directly — it used to go through a `NotificationCenter` hop, which was
    /// indirection with no benefit and one more thing that could silently not fire.
    var isSyncPanelPresented = false

    /// The welcome sheet (Phase 8): shown on a first launch with nothing configured, and from
    /// Help ▸ Getting Started.
    var isWelcomePresented = false

    /// The last Test Connection result, and whether one is running.
    private(set) var connectionCheck: ConnectionCheck?
    private(set) var isCheckingConnection = false
    /// What a running check is waiting for — the listing takes a while on a healthy phone.
    private(set) var connectionProgress = "" 

    /// Checks the phone, the token, and that workouts come back. The handshake has a short
    /// deadline, so an absent phone answers in seconds; the listing that follows is slow on a
    /// healthy phone and gets longer (see `ConnectionCheck`). Not while a sync runs: Health Auto
    /// Export serves one client at a time.
    func checkConnection() async {
        guard !isCheckingConnection, !syncStatus.isRunning,
              let source = settings.makeSource(timeout: ConnectionCheck.requestTimeout) else { return }
        isCheckingConnection = true
        connectionCheck = nil
        connectionProgress = "Connecting…"
        connectionCheck = await ConnectionCheck.run(source) { server in
            await MainActor.run {
                self.connectionProgress = "Connected to \(server) — reading the last week's workouts…"
            }
        }
        isCheckingConnection = false
    }

    func clearConnectionCheck() {
        if !isCheckingConnection { connectionCheck = nil }
    }

    /// The selection a "New Tag…" prompt will apply to, while it's showing.
    var newTagTargets: Set<String>?

    /// Whether the detail inspector is open. Starts **hidden**, so the table gets the whole window
    /// until there is something to put in it.
    ///
    /// Held here rather than as view state because the *scene* needs it: the window's minimum
    /// width depends on it (see `MaxActApp`). Safe to share now that the app is one window.
    var showsDetail = false

    /// A workout the table should scroll to, set by ``reveal(_:)``. A fresh value each time, so
    /// revealing the same workout twice still scrolls.
    private(set) var revealRequest: RevealRequest?

    struct RevealRequest: Equatable {
        let workoutID: String
        let serial: Int
        /// The table identity current when it was made. If clearing the search rebuilt the table
        /// in the same update, the new table has no rows yet when the request arrives, so the view
        /// scrolls again once that table has appeared (issue 44).
        let tableIdentity: Int
    }

    /// The narrowest window that holds sidebar, table and inspector at their minimums.
    ///
    /// Measured, not summed: at 1,300pt with the inspector open the table sat at 664pt against a
    /// floor of 562pt, so the three panes need 1,300 − 102 ≈ 1,200. Below that SwiftUI doesn't
    /// shrink anything further — it lays the content out wider than the window and centres it,
    /// which clipped 9pt off both edges and is what erased the sidebar's inset.
    static let minimumWidthWithInspector: CGFloat = 1200
    static let minimumWidth: CGFloat = 1040

    /// The window's minimum for what's on screen now. The inspector is never shown beside the
    /// statistics (see `ContentView.systemInspectorPresented`), so only the list needs the extra room.
    var minimumWindowWidth: CGFloat {
        showsDetail && sidebarSelection != .statistics ? Self.minimumWidthWithInspector : Self.minimumWidth
    }

    // MARK: Sync

    /// Set by the job runner and the passes in `AppModel+Sync` and `AppModel+Strava`; views read it.
    var syncStatus: SyncStatus = .idle

    // MARK: Dependencies

    let store: WorkoutStore
    let seriesStore: SeriesStore
    /// Bumped each time a workout's series is written or discarded (issue 38), so the inspector
    /// reloads it: keyed on the selection alone, it stayed empty after Download Detail and kept
    /// the old route after a re-download or a fill from Strava.
    private(set) var seriesRevisions: [String: Int] = [:]
    @ObservationIgnored private var observesSeries = false

    /// The heat map's route sketches (issue 15), cached beside the series they come from.
    let routeSketchCache: RouteSketchCache?
    /// Built sketches by workout id, once `loadRouteSketches` has run.
    private(set) var routeSketches: [String: RouteSketch] = [:] {
        didSet { sketchGeneration += 1 }
    }
    @ObservationIgnored private var sketchGeneration = 0
    @ObservationIgnored private var regionsMemo: (key: RegionsKey, regions: [RouteRegion])?

    private struct RegionsKey: Equatable {
        let workoutIDs: [String]
        let placeNames: [String: String]
        let sketchGeneration: Int
    }
    /// The same sketches prepared for matching routes (issue 23), built alongside them: preparing
    /// the library takes longer than one lookup, so it isn't redone per selection.
    private(set) var preparedRoutes: [String: RouteMatcher.Prepared] = [:]
    /// Time at each heart rate by workout id, read in the same pass as the sketches — the
    /// heart-rate zones' data (issue 15).
    private(set) var heartRateHistograms: [String: HeartRateHistogram] = [:]
    @ObservationIgnored var isRepairingHeartRate = false
    @ObservationIgnored var isFillingRoutes = false
    /// (done, total) while sketches are being built for the first time.
    private(set) var routeSketchProgress: (done: Int, total: Int)?
    let thumbnails: RouteThumbnailRenderer
    let settings: AppSettings

    /// Number of synthetic workouts to plant on first load, for UI tests and previews. `nil` in
    /// normal use.
    let seedCount: Int?

    /// Whether to reverse-geocode place names. Off under UI testing: it is a network call, and a
    /// test suite that depends on Apple's geocoder is a test suite that fails on a train.
    let resolvesPlaces: Bool

    /// The one job at a time against Health Auto Export or Strava (issue 39). See `startJob`.
    @ObservationIgnored var job: Task<Void, Never>?
    /// Stop was asked for, and the job is finishing what it had in flight.
    var isStopping = false
    private var hasSeeded = false

    // MARK: Strava

    /// Where the Strava application credentials and tokens live: the Keychain normally, memory
    /// under UI testing, so a test can never sign the real account out or raise a password prompt.
    let stravaSecrets: any AppSecretStore
    let strava: StravaClient

    /// Whether a client ID and secret have been entered, and whose account is connected.
    var isStravaConfigured = false
    var stravaAthlete: String?
    /// Why the Keychain couldn't be read, when that's why Strava looks disconnected (issue 40).
    var stravaReadProblem: String?
    var isStravaConnected: Bool { stravaAthlete != nil }
    var hasResumedUploads = false
    var flagPushTask: Task<Void, Never>?
    /// The quiet resume of uploads a previous run left in flight.
    @ObservationIgnored var resumeTask: Task<Void, Never>?

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
        stravaSecrets: any AppSecretStore = KeychainSecretStore(),
        stravaTransport: any StravaTransport = URLSessionStravaTransport()
    ) {
        self.stravaSecrets = stravaSecrets
        strava = StravaClient(transport: stravaTransport, secrets: stravaSecrets)
        self.store = store
        self.seriesStore = seriesStore
        routeSketchCache = try? RouteSketchCache(directory: seriesStore.directory.deletingLastPathComponent())
        self.thumbnails = thumbnails
        self.settings = settings
        sidebarSelection = SidebarSelection(storageKey: settings.sidebarSelectionKey) ?? .filter(.all)
        sortOrder = TableSort.order(storageKey: settings.tableSortKey) ?? TableSort.default
        self.seedCount = seedCount
        self.resolvesPlaces = resolvesPlaces
        placeResolver = PlaceResolver(store: store)
    }

    /// A model over a **copy** of a real library, for UI tests that need real content — how long
    /// real place names are, how wide real numbers run — without touching the real one.
    ///
    /// Everything else stays isolated exactly as for seeded UI tests: in-memory secrets, no
    /// geocoding, throwaway settings. The copy lives in the app's own temporary directory, so the
    /// sandbox allows it, and a normal launch never looks there. Returns `nil` if no copy exists.
    static func copyOfRealLibrary(in directory: URL, settings: AppSettings) -> AppModel? {
        let storeURL = directory.appending(path: "default.store")
        guard FileManager.default.fileExists(atPath: storeURL.path(percentEncoded: false)),
              let container = try? WorkoutStore.container(at: storeURL),
              let seriesStore = try? SeriesStore(directory: directory.appending(path: "Series")),
              let thumbnails = try? RouteThumbnailRenderer(
                  seriesStore: seriesStore, directory: directory.appending(path: "Thumbnails"))
        else { return nil }
        return AppModel(
            store: WorkoutStore(modelContainer: container),
            seriesStore: seriesStore,
            thumbnails: thumbnails,
            settings: settings,
            resolvesPlaces: false,
            stravaSecrets: InMemorySecretStore()
        )
    }

    /// Used when the on-disk stores can't be opened, and by tests. Everything works; nothing
    /// persists.
    static func inMemoryFallback(
        settings: AppSettings, seedCount: Int? = nil, resolvesPlaces: Bool = true,
        stravaSecrets: any AppSecretStore = KeychainSecretStore(),
        stravaTransport: any StravaTransport = URLSessionStravaTransport()
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
            stravaSecrets: stravaSecrets,
            stravaTransport: stravaTransport
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

    /// Selects one workout, shows it in the inspector and scrolls the table to it — for links from
    /// elsewhere, like the Same Route chart. If the current search or filter hides it, the table
    /// goes back to All Workouts first: the inspector only shows workouts the table lists.
    func reveal(_ workoutID: String) {
        guard items.contains(where: { $0.id == workoutID }), selection != [workoutID] else { return }
        backStack.append(currentPlace)
        if backStack.count > Self.historyLimit { backStack.removeFirst() }
        forwardStack.removeAll()
        if !visibleItems.contains(where: { $0.id == workoutID }) {
            searchText = ""
            sidebarSelection = .filter(.all)
        }
        show([workoutID])
    }

    // MARK: Back and Forward (issue 32)

    /// Where the user was before a jump: the selection and the view it was seen in. Restoring
    /// the view too means Back undoes a jump that had to clear a search or filter.
    struct Place: Equatable {
        let selection: Set<String>
        let sidebarSelection: SidebarSelection?
        let searchText: String
    }

    /// Places left by jumps (`reveal`), newest last. Only jumps add to it — clicking around the
    /// table doesn't — so Back always returns to where a jump started (decided with the user).
    private(set) var backStack: [Place] = []
    private(set) var forwardStack: [Place] = []
    private static let historyLimit = 50

    var canGoBack: Bool { !backStack.isEmpty }
    var canGoForward: Bool { !forwardStack.isEmpty }

    func goBack() {
        guard let place = backStack.popLast() else { return }
        forwardStack.append(currentPlace)
        restore(place)
    }

    func goForward() {
        guard let place = forwardStack.popLast() else { return }
        backStack.append(currentPlace)
        restore(place)
    }

    private var currentPlace: Place {
        Place(selection: selection, sidebarSelection: sidebarSelection, searchText: searchText)
    }

    private func restore(_ place: Place) {
        sidebarSelection = place.sidebarSelection
        searchText = place.searchText
        // Workouts deleted since are simply dropped.
        show(place.selection.filter { id in items.contains { $0.id == id } })
    }

    /// Selects `ids`, opens the inspector, and scrolls the table to a single selection.
    private func show(_ ids: Set<String>) {
        selection = ids
        guard let only = ids.first, ids.count == 1 else { return }
        showsDetail = true
        revealRequest = RevealRequest(workoutID: only, serial: (revealRequest?.serial ?? 0) + 1,
                                      tableIdentity: tableIdentity)
    }

    /// The table's rows, and an identity for the table that changes when an update would insert
    /// many rows at once (issue 44).
    ///
    /// SwiftUI's `Table` inserts scattered rows slowly: deleting "California" back to "Ca", 29
    /// rows becoming 473 took 6.5 s on the user's library — not the filtering (6 ms), nor the
    /// cells (plain text took as long), nor animation or column customization (measured). Building
    /// the table afresh took ~350 ms. So a big insertion gets a fresh table; small changes keep the
    /// diff, and with it the scroll position.
    private(set) var tableIdentity = 0

    /// Decided when the search or sidebar changes, before the table redraws: decided while
    /// drawing, the old table still took the insertions first (1.8 s against ~0.6 s, measured).
    private func noteRowChange() {
        let ids = Set(visibleItems.map(\.id))
        // Starts empty, so the first search or sidebar change also builds the table afresh. That
        // looks wasteful, but measured: without it, deleting "California" back to "Ca" took 1.8 s
        // (three runs); with it, 0.5 s (two runs).
        if ids.subtracting(shownRowIDs).count > Self.rebuildAbove { tableIdentity += 1 }
        shownRowIDs = ids
    }

    /// Inserting more rows than this rebuilds the table: ~16 ms a row against ~350 ms a rebuild.
    static let rebuildAbove = 20
    @ObservationIgnored private var shownRowIDs: Set<String> = []

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

    /// Tags on at least one workout, in display order.
    var usedTags: [String] {
        WorkoutTag.sorted(Array(Set(items.flatMap(\.tags))))
    }

    /// Every tag worth offering in a menu: the ones in use, plus Commute and Trainer always.
    var allTags: [String] {
        WorkoutTag.sorted(Array(Set(items.flatMap(\.tags)).union(WorkoutTag.stravaBacked)))
    }

    /// The highest heart rate any workout recorded — a starting point for the maximum.
    var suggestedMaximumHeartRate: Int? {
        TrainingLoad.suggestedMaximum(from: items.map(\.workout)).map { Int($0.rounded()) }
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
        await observeSeriesChanges()
        do {
            try await seedIfRequested()
            items = try await store.allItems()
            loadError = nil
            checkRestoredSelection()
        } catch {
            loadError = "Could not load workouts: \(error.localizedDescription)"
        }
        resolvePlaces()
        await refreshStravaConnection()
        resumeStravaUploads()
        await repairSparseHeartRateIfNeeded()
        await markRepairsForRedownloadIfNeeded()
        await fillIncompleteRoutesIfNeeded()
    }

    private func observeSeriesChanges() async {
        guard !observesSeries else { return }
        observesSeries = true
        await seriesStore.observe { [weak self] id, change in
            Task { @MainActor in await self?.seriesChanged(id, change) }
        }
    }

    private func seriesChanged(_ workoutID: String, _ change: SeriesStore.Change) async {
        seriesRevisions[workoutID, default: 0] += 1
        guard change == .discardedDamaged else { return }
        // Damaged and removed: offer it for download again, rather than counting it as
        // downloaded with nothing to show.
        do {
            try await store.markDetailMissing(workoutID)
        } catch {
            Self.log.error("Couldn't mark \(workoutID, privacy: .public) for re-download: \(String(describing: error), privacy: .public)")
        }
        await routeSketchCache?.invalidate([workoutID])
        thumbnails.delete(workoutID: workoutID)
        items = (try? await store.allItems()) ?? items
    }

    /// Once: workouts repaired before repairs were recorded go back to needing detail, so the next
    /// Download Detail re-fetches them and records exactly what was repaired (issue 22).
    private func markRepairsForRedownloadIfNeeded() async {
        guard !settings.hasMarkedRepairsForRedownload, items.contains(where: \.hasDetail) else { return }
        let marked: [String]
        do {
            marked = try await store.markRepairedSourcesForRedownload(seriesStore: seriesStore)
        } catch {
            Self.log.error("Couldn't mark repaired workouts for re-download (tried again next launch): \(String(describing: error), privacy: .public)")
            return
        }
        settings.hasMarkedRepairsForRedownload = true
        if !marked.isEmpty {
            await routeSketchCache?.invalidate(marked)
            items = (try? await store.allItems()) ?? items
        }
    }

    /// Once per library: workouts whose heart rate the workout export averaged into a few readings
    /// (Apple Workout app recordings, measured 17 of 418) are marked as needing detail, so the
    /// Download Detail action re-fetches them — the detail fetch now fills in the dense heart rate.
    /// Reads every series (~7 s for 418), off the main actor.
    private func repairSparseHeartRateIfNeeded() async {
        guard !settings.hasRepairedSparseHeartRate, !isRepairingHeartRate, items.contains(where: \.hasDetail) else { return }
        isRepairingHeartRate = true
        defer { isRepairingHeartRate = false }
        let marked: [String]
        do {
            marked = try await store.markSparseHeartRateForRedownload(seriesStore: seriesStore)
        } catch {
            Self.log.error("Couldn't mark sparse heart rate for re-download (tried again next launch): \(String(describing: error), privacy: .public)")
            return
        }
        settings.hasRepairedSparseHeartRate = true
        if !marked.isEmpty {
            await routeSketchCache?.invalidate(marked)
            items = (try? await store.allItems()) ?? items
        }
    }

    /// A remembered activity or tag can be gone by the next launch — its last workout deleted or
    /// untagged — and an empty list under a sidebar row that no longer exists would be baffling.
    /// Checked once, after the first load: later in a session, emptying the row you're looking at
    /// should leave you there.
    private func checkRestoredSelection() {
        guard !hasCheckedRestoredSelection else { return }
        hasCheckedRestoredSelection = true
        switch sidebarSelection {
        case .kind(let key) where !presentKinds.contains(where: { $0.key == key }):
            sidebarSelection = .filter(.all)
        case .tag(let name) where !usedTags.contains(name):
            sidebarSelection = .filter(.all)
        default:
            break
        }
    }

    // MARK: Route colouring

    /// Colours one workout's route (issue 31): per workout, so only its own thumbnail redraws.
    func setRouteColoring(_ coloring: RouteColoring, for workoutID: String) {
        Task {
            do {
                try await store.setRouteColoring(coloring, for: workoutID)
            } catch {
                reportFailedChange("Couldn't change the route's colouring", error)
            }
            await refreshItems()
        }
    }

    // MARK: Tags

    func addTag(_ name: String, to ids: Set<String>) {
        guard let name = WorkoutTag.normalized(name, existing: allTags) else { return }
        Task {
            var needsPush: [String] = []
            do {
                needsPush = try await store.addTag(name, to: Array(ids))
            } catch {
                reportFailedChange("Couldn't add the tag \"\(name)\"", error)
            }
            await refreshItems()
            if !needsPush.isEmpty { pushPendingStravaFlags() }
        }
    }

    func removeTag(_ name: String, from ids: Set<String>) {
        Task {
            var needsPush: [String] = []
            do {
                needsPush = try await store.removeTag(name, from: Array(ids))
            } catch {
                reportFailedChange("Couldn't remove the tag \"\(name)\"", error)
            }
            await refreshItems()
            if !needsPush.isEmpty { pushPendingStravaFlags() }
        }
    }

    /// Cheaper than `load()`: no place resolution, no Strava resume.
    func refreshItems() async {
        do {
            items = try await store.allItems()
        } catch {
            // The table keeps what it showed; the next load reports a lasting failure.
            Self.log.error("Couldn't refresh the table: \(String(describing: error), privacy: .public)")
        }
    }

    /// A change the user asked for that didn't take (issue 40): shown, since otherwise it looks as
    /// if it worked until the next launch, and logged.
    func reportFailedChange(_ what: String, _ error: any Error) {
        Self.log.error("\(what, privacy: .public): \(String(describing: error), privacy: .public)")
        loadError = "\(what): \(error.localizedDescription)"
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
            do {
                _ = try await store.backfillPlaceCoordinates(seriesStore: seriesStore)
            } catch {
                Self.log.error("Couldn't backfill place coordinates: \(String(describing: error), privacy: .public)")
            }

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

    // MARK: Route sketches

    /// Sketches and heart-rate histograms for every workout with detail, newest first, building only the ones not yet cached.
    /// The first run over a full library takes a while (measured 9 s for 418 routes, debug), so
    /// it reports progress; afterwards it's a single file read.
    func loadRouteSketches() async {
        guard let cache = routeSketchCache, routeSketchProgress == nil else { return }
        let ids = items.filter(\.hasDetail).sorted { $0.workout.start > $1.workout.start }.map(\.id)
        routeSketchProgress = (0, 0)
        let built = await cache.digests(for: ids, seriesStore: seriesStore) { done, total in
            await MainActor.run { self.routeSketchProgress = (done, total) }
        }
        routeSketches = Dictionary(built.compactMap { digest in digest.sketch.map { (digest.workoutID, $0) } },
                                   uniquingKeysWith: { first, _ in first })
        heartRateHistograms = Dictionary(built.map { ($0.workoutID, $0.heartRate) }, uniquingKeysWith: { first, _ in first })
        let sketches = routeSketches
        preparedRoutes = await Task.detached(priority: .userInitiated) {
            sketches.compactMapValues { RouteMatcher.Prepared($0.coordinates) }
        }.value
        routeSketchProgress = nil
    }

    /// The heatmap's places for these sketches, worked out again only when the routes shown, the
    /// sketches themselves or the place names change (issue 41). Measured on the user's library:
    /// 238 ms each time, and it ran on every Statistics redraw — every hover, every model change.
    func heatmapRegions(_ sketches: [RouteSketch], placeNames: [String: String]) -> [RouteRegion] {
        let key = RegionsKey(workoutIDs: sketches.map(\.workoutID), placeNames: placeNames,
                             sketchGeneration: sketchGeneration)
        if let regionsMemo, regionsMemo.key == key { return regionsMemo.regions }
        let regions = RouteHeatmap.regions(sketches, placeNames: placeNames)
        regionsMemo = (key, regions)
        return regions
    }

    /// Every time `item`'s route has been done (issue 23), or `nil` if it hasn't been done before
    /// or has no route. Loads the sketches first if this workout's isn't in hand — the first time
    /// over a full library, that's the slow part. The matching itself runs off the main actor.
    func routeHistory(for item: WorkoutListItem) async -> RouteHistory? {
        guard item.hasDetail, item.workout.hasRoute else { return nil }
        if preparedRoutes[item.id] == nil { await loadRouteSketches() }
        let routes = preparedRoutes
        let workout = item.workout
        let candidates = items.filter { $0.workout.kind == workout.kind }.map(\.workout)
        return await Task.detached(priority: .userInitiated) {
            RouteHistory(for: workout, routes: routes, among: candidates)
        }.value
    }

    func dismissLoadError() {
        loadError = nil
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
        // Not while a job is writing (issue 39): the button is disabled then, and this is the
        // backstop. Background passes are waited out instead — a route fill finishing after the
        // delete would leave an orphan series a later re-sync adopts.
        guard !syncStatus.isRunning else { return }
        placeTask?.cancel()
        await placeTask?.value
        await waitForQuietStravaWork()
        while isFillingRoutes || isRepairingHeartRate { try? await Task.sleep(for: .milliseconds(100)) }
        do {
            try await store.deleteAll()
            try await seriesStore.deleteAll()
            try thumbnails.deleteAll()
            await routeSketchCache?.clear()
            routeSketches = [:]
            preparedRoutes = [:]
            heartRateHistograms = [:]
            selection.removeAll()
            hasSeeded = true   // don't re-seed a store the user just asked to empty
            await load()
            syncStatus = .idle
        } catch {
            loadError = "Could not delete data: \(error.localizedDescription)"
        }
    }

    static let log = Logger(subsystem: "com.swiatlowski.MaxAct", category: "sync")
}
