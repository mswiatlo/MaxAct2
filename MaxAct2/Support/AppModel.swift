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
    }

    enum SyncStatus: Equatable {
        case idle
        case running(SyncActivity, completed: Int, total: Int, found: Int)
        case finished(SyncActivity, found: Int)
        case failed(String)

        var isRunning: Bool { if case .running = self { true } else { false } }

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

    private var syncTask: Task<Void, Never>?
    private var hasSeeded = false

    init(
        store: WorkoutStore,
        seriesStore: SeriesStore,
        thumbnails: RouteThumbnailRenderer,
        settings: AppSettings,
        seedCount: Int? = nil
    ) {
        self.store = store
        self.seriesStore = seriesStore
        self.thumbnails = thumbnails
        self.settings = settings
        self.seedCount = seedCount
    }

    /// Used when the on-disk stores can't be opened. Everything works; nothing persists.
    static func inMemoryFallback(settings: AppSettings, seedCount: Int? = nil) -> AppModel {
        // Force-unwrapped deliberately: an in-memory container and a temp directory failing
        // would mean the process cannot allocate or write anywhere, and there is no recovery.
        let scratch = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "MaxActFallback-\(UUID().uuidString)")
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
            seedCount: seedCount
        )
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
