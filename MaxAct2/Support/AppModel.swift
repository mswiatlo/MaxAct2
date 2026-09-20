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

    // MARK: Sync

    private(set) var syncStatus: SyncStatus = .idle

    enum SyncStatus: Equatable {
        case idle
        case running(completed: Int, total: Int, found: Int)
        case finished(found: Int)
        case failed(String)

        var isRunning: Bool { if case .running = self { true } else { false } }

        var message: String? {
            switch self {
            case .idle: nil
            case .running(let done, let total, let found):
                "Syncing week \(done + 1) of \(total) — \(found) workouts so far"
            case .finished(let found):
                found == 0 ? "No new workouts" : "Synced \(found) workouts"
            case .failed(let reason): reason
            }
        }
    }

    // MARK: Dependencies

    let store: WorkoutStore
    let seriesStore: SeriesStore
    let thumbnails: RouteThumbnailRenderer
    let settings: SyncSettings

    private var syncTask: Task<Void, Never>?

    init(
        store: WorkoutStore,
        seriesStore: SeriesStore,
        thumbnails: RouteThumbnailRenderer,
        settings: SyncSettings
    ) {
        self.store = store
        self.seriesStore = seriesStore
        self.thumbnails = thumbnails
        self.settings = settings
    }

    /// Used when the on-disk stores can't be opened. Everything works; nothing persists.
    static func inMemoryFallback(settings: SyncSettings) -> AppModel {
        // Force-unwrapped deliberately: an in-memory container and a temp directory failing
        // would mean the process cannot allocate or write anywhere, and there is no recovery.
        let seriesStore = try! SeriesStore(
            directory: URL(fileURLWithPath: NSTemporaryDirectory())
                .appending(path: "MaxActFallback-\(UUID().uuidString)")
        )
        return AppModel(
            store: WorkoutStore(modelContainer: try! WorkoutStore.container(inMemory: true)),
            seriesStore: seriesStore,
            thumbnails: try! RouteThumbnailRenderer(seriesStore: seriesStore),
            settings: settings
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

    // MARK: Actions

    func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            items = try await store.allItems()
            loadError = nil
        } catch {
            loadError = "Could not load workouts: \(error.localizedDescription)"
        }
    }

    func selectAllVisible() {
        selection = Set(visibleItems.map(\.id))
    }

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
        syncStatus = .running(completed: 0, total: windows.count, found: 0)

        do {
            try await source.connect()
            var found = 0
            for (index, window) in windows.enumerated() {
                if Task.isCancelled { break }
                let result = try await source.listWorkouts(in: window)
                try await store.upsert(result.workouts)
                found += result.workouts.count
                syncStatus = .running(completed: index + 1, total: windows.count, found: found)
                await load()
            }
            syncStatus = .finished(found: found)
        } catch {
            // Partial progress is kept: every completed chunk is already committed.
            syncStatus = .failed(Self.describe(error))
        }
    }

    /// Fetches routes and second-resolution series for specific workouts.
    func fetchDetail(for workouts: [WorkoutListItem], source: HAEWorkoutSource) async {
        guard !syncStatus.isRunning else { return }
        syncStatus = .running(completed: 0, total: workouts.count, found: 0)
        do {
            try await source.connect()
            var fetched = 0
            for (index, item) in workouts.enumerated() where !item.hasDetail {
                if Task.isCancelled { break }
                if let detail = try await source.fetchDetail(for: item.workout) {
                    try await store.upsert([detail], seriesStore: seriesStore)
                    fetched += 1
                }
                syncStatus = .running(completed: index + 1, total: workouts.count, found: fetched)
            }
            await load()
            syncStatus = .finished(found: fetched)
        } catch {
            await load()
            syncStatus = .failed(Self.describe(error))
        }
    }

    func dismissSyncStatus() {
        syncStatus = .idle
    }

    // MARK: Task lifecycle

    /// Starts a full list-pass sync over the configured backfill span.
    func startSync() {
        guard let source = settings.makeSource(), !syncStatus.isRunning else { return }
        let start = Calendar.current.date(
            byAdding: .year, value: -settings.backfillYears, to: .now
        ) ?? .now.addingTimeInterval(-365 * 24 * 3600)
        syncTask = Task { await sync(source: source, from: start) }
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
