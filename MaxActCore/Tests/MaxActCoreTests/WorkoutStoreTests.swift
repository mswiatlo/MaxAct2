import Foundation
import SwiftData
import Testing

@testable import MaxActCore

@Suite struct WorkoutStoreTests {

    private func makeStore() throws -> WorkoutStore {
        WorkoutStore(modelContainer: try WorkoutStore.container(inMemory: true))
    }

    private func makeSeriesStore() throws -> SeriesStore {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "MaxActTests-\(UUID().uuidString)")
        return try SeriesStore(directory: directory)
    }

    private func workout(
        id: String = "W1",
        kind: ActivityKind = .cycling,
        start: Date = Date(timeIntervalSince1970: 1_700_000_000),
        distance: Double? = 10_000,
        energy: Double? = 250,
        hasRoute: Bool = false
    ) -> Workout {
        Workout(
            id: id, kind: kind, start: start, end: start.addingTimeInterval(3600),
            duration: 3600, distanceMeters: distance, activeEnergyKilocalories: energy,
            averageHeartRate: 140, hasRoute: hasRoute
        )
    }

    private func ingested(_ workout: Workout, series: WorkoutSeries? = nil) -> IngestedWorkout {
        IngestedWorkout(workout: workout, series: series ?? WorkoutSeries(workoutID: workout.id))
    }

    private func series(
        id: String = "W1", routePoints: Int = 3, heartRateSamples: Int = 2
    ) -> WorkoutSeries {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        return WorkoutSeries(
            workoutID: id,
            route: (0..<routePoints).map { i in
                RoutePoint(
                    coordinate: Coordinate(latitude: 49.25 + Double(i) * 0.001, longitude: -123.1),
                    timestamp: base.addingTimeInterval(Double(i)),
                    altitudeMeters: 60 + Double(i)
                )
            },
            heartRate: (0..<heartRateSamples).map { i in
                HeartRateSample(
                    date: base.addingTimeInterval(Double(i) * 5),
                    minimum: 120, average: 130, maximum: 140
                )
            }
        )
    }

    // MARK: - Idempotency

    @Test("re-syncing the same window updates rather than duplicating")
    func upsertIsIdempotent() async throws {
        let store = try makeStore()
        let summary1 = try await store.upsert([ingested(workout())])
        let summary2 = try await store.upsert([ingested(workout())])

        #expect(summary1.inserted == 1)
        #expect(summary2.inserted == 0)
        #expect(summary2.updated == 1)
        #expect(try await store.count() == 1)
    }

    @Test("Strava state survives a re-sync — the failure that would cause duplicate uploads")
    func localStateSurvivesReimport() async throws {
        let store = try makeStore()
        try await store.upsert([ingested(workout())])
        try await store.setStravaState(.uploaded, activityID: 998877, for: "W1")
        try await store.setPlaceLabel("Vancouver, BC", for: "W1")
        try await store.setThumbnailFileName("W1.png", for: "W1")

        // A later sync brings the same workout back with slightly different imported numbers.
        try await store.upsert([ingested(workout(distance: 10_500, energy: 260))])

        let item = try #require(try await store.item(id: "W1"))
        #expect(item.stravaState == .uploaded)
        #expect(item.stravaActivityID == 998877)
        #expect(item.placeLabel == "Vancouver, BC")
        #expect(item.thumbnailFileName == "W1.png")
        // …while the imported side did update.
        #expect(item.workout.distanceMeters == 10_500)
    }

    @Test("a list-pass re-sync does not erase the knowledge that a route exists")
    func hasRouteIsNotErasedByListPass() async throws {
        let store = try makeStore()
        // Detail pass: routes present.
        try await store.upsert([ingested(workout(hasRoute: true))])
        // List pass: fetched with includeRoutes false, so hasRoute is false in the payload.
        try await store.upsert([ingested(workout(hasRoute: false))])

        let item = try #require(try await store.item(id: "W1"))
        #expect(item.workout.hasRoute, "hasRoute must be OR-ed, not assigned")
    }

    @Test("a re-sync missing an optional field keeps the previously known value")
    func absentFieldsDoNotWipeKnownValues() async throws {
        let store = try makeStore()
        try await store.upsert([ingested(workout(distance: 10_000, energy: 250))])
        try await store.upsert([ingested(workout(distance: nil, energy: nil))])

        let item = try #require(try await store.item(id: "W1"))
        #expect(item.workout.distanceMeters == 10_000)
        #expect(item.workout.activeEnergyKilocalories == 250)
    }

    // MARK: - Series blobs

    @Test("a series round-trips through compression unchanged")
    func seriesRoundTrip() async throws {
        let seriesStore = try makeSeriesStore()
        let original = series(routePoints: 500, heartRateSamples: 200)
        try await seriesStore.save(original)
        let loaded = try await seriesStore.load("W1")
        #expect(loaded == original)
    }

    @Test("a missing series reads as unavailable rather than crashing")
    func missingSeriesDegrades() async throws {
        let seriesStore = try makeSeriesStore()
        #expect(await seriesStore.loadIfAvailable("nope") == nil)
        await #expect(throws: SeriesStore.StoreError.self) { try await seriesStore.load("nope") }
    }

    @Test("a truncated blob is reported as corrupt, not decoded into nonsense")
    func corruptSeriesDegrades() async throws {
        let seriesStore = try makeSeriesStore()
        try await seriesStore.save(series(routePoints: 200))

        // Truncate mid-stream, as an interrupted copy by some other tool would.
        let url = await seriesStore.fileURL(for: "W1")
        let intact = try Data(contentsOf: url)
        try intact.prefix(intact.count / 3).write(to: url)

        await #expect(throws: SeriesStore.StoreError.self) { try await seriesStore.load("W1") }
        #expect(await seriesStore.loadIfAvailable("W1") == nil, "views must degrade, not crash")
    }

    @Test("the list pass does not overwrite a stored detail blob with an empty one")
    func emptySeriesDoesNotClobberDetail() async throws {
        let store = try makeStore()
        let seriesStore = try makeSeriesStore()

        try await store.upsert([ingested(workout(hasRoute: true), series: series())], seriesStore: seriesStore)
        #expect(try #require(try await store.item(id: "W1")).hasDetail)

        // List pass: same workout, no series at all.
        let summary = try await store.upsert([ingested(workout())], seriesStore: seriesStore)
        #expect(summary.seriesStored == 0)

        let stored = try await seriesStore.load("W1")
        #expect(stored.route.count == 3, "the detail blob should be untouched")
        #expect(try #require(try await store.item(id: "W1")).hasDetail)
    }

    @Test("detail flags can be reconciled against what is actually on disk")
    func reconcileDetailFlags() async throws {
        let store = try makeStore()
        let seriesStore = try makeSeriesStore()
        try await store.upsert([ingested(workout(hasRoute: true), series: series())], seriesStore: seriesStore)

        // The blob disappears behind the database's back.
        try await seriesStore.delete("W1")
        #expect(try #require(try await store.item(id: "W1")).hasDetail, "flag is now stale")

        let corrected = try await store.reconcileDetailFlags(with: seriesStore)
        #expect(corrected == 1)
        #expect(try #require(try await store.item(id: "W1")).hasDetail == false)
    }

    // MARK: - Queries

    @Test("rows come back newest first, which is how the table opens")
    func sortOrder() async throws {
        let store = try makeStore()
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        try await store.upsert([
            ingested(workout(id: "old", start: base)),
            ingested(workout(id: "new", start: base.addingTimeInterval(86_400))),
        ])
        #expect(try await store.allItems().map(\.id) == ["new", "old"])
    }

    @Test("the not-on-Strava query excludes both uploaded and duplicate")
    func notOnStravaQuery() async throws {
        let store = try makeStore()
        try await store.upsert([
            ingested(workout(id: "a")), ingested(workout(id: "b")),
            ingested(workout(id: "c")), ingested(workout(id: "d")),
        ])
        try await store.setStravaState(.uploaded, for: "a")
        try await store.setStravaState(.duplicate, for: "b")
        try await store.setStravaState(.failed(reason: "429"), for: "c")

        let pending = try await store.itemsNotOnStrava().map(\.id).sorted()
        #expect(pending == ["c", "d"], "a failed upload still needs attention")
    }

    @Test("a failed upload keeps its reason readable")
    func failureReasonPersists() async throws {
        let store = try makeStore()
        try await store.upsert([ingested(workout())])
        try await store.setStravaState(.failed(reason: "rate limited"), for: "W1")

        let item = try #require(try await store.item(id: "W1"))
        #expect(item.stravaState == .failed(reason: "rate limited"))
        #expect(item.stravaState.label.contains("rate limited"))
    }

    @Test("polling progress does not erase an activity id already recorded")
    func idsAreNotErasedByLaterUpdates() async throws {
        let store = try makeStore()
        try await store.upsert([ingested(workout())])
        try await store.setStravaState(.uploaded, activityID: 123, for: "W1")
        try await store.setStravaState(.uploaded, for: "W1")  // no id supplied

        #expect(try #require(try await store.item(id: "W1")).stravaActivityID == 123)
    }

    @Test("the detail backlog lists only workouts without stored series")
    func detailBacklog() async throws {
        let store = try makeStore()
        let seriesStore = try makeSeriesStore()
        try await store.upsert([
            ingested(workout(id: "withDetail", hasRoute: true), series: series(id: "withDetail")),
            ingested(workout(id: "without")),
        ], seriesStore: seriesStore)

        #expect(try await store.itemsNeedingDetail().map(\.id) == ["without"])
    }

    // MARK: - Round-tripping enums

    @Test("an unrecognised activity name survives persistence")
    func unknownActivityKindRoundTrips() async throws {
        let store = try makeStore()
        let kind = ActivityKind.other("Underwater Basket Weaving")
        try await store.upsert([ingested(workout(kind: kind))])

        let item = try #require(try await store.item(id: "W1"))
        #expect(item.workout.kind == kind)
    }

    @Test("every Strava state round-trips through its storage key", arguments: [
        StravaState.notUploaded, .queued, .uploading, .uploaded, .duplicate, .failed(reason: "boom"),
    ])
    func stravaStateRoundTrips(state: StravaState) {
        let restored = StravaState(storageKey: state.storageKey, failureReason: state.failureReason)
        #expect(restored == state)
    }

    // MARK: - Deletion

    @Test("deleting everything empties the store")
    func deleteAllClearsRows() async throws {
        let store = try makeStore()
        try await store.upsert((0..<5).map { ingested(workout(id: "W\($0)")) })
        #expect(try await store.count() == 5)

        #expect(try await store.deleteAll() == 5)
        #expect(try await store.count() == 0)
        #expect(try await store.allItems().isEmpty)
    }

    @Test("deleting everything also clears the series blobs")
    func deleteAllClearsSeries() async throws {
        let seriesStore = try makeSeriesStore()
        try await seriesStore.save(series(id: "A"))
        try await seriesStore.save(series(id: "B"))
        #expect(try await seriesStore.totalBytes() > 0)

        #expect(try await seriesStore.deleteAll() == 2)
        #expect(try await seriesStore.totalBytes() == 0)
        #expect(await seriesStore.loadIfAvailable("A") == nil)
    }

    /// Series and rows are both keyed on the HealthKit UUID, so a leftover blob would be silently
    /// adopted by a re-synced workout with the same id — showing a deleted workout's route on a
    /// freshly imported one.
    @Test("a re-sync after deletion does not inherit orphaned series")
    func reSyncAfterDeletionIsClean() async throws {
        let store = try makeStore()
        let seriesStore = try makeSeriesStore()
        try await store.upsert(
            [ingested(workout(hasRoute: true), series: series())], seriesStore: seriesStore
        )

        try await store.deleteAll()
        try await seriesStore.deleteAll()

        // The same workout arrives again from a list pass, with no series.
        try await store.upsert([ingested(workout())], seriesStore: seriesStore)
        let item = try #require(try await store.item(id: "W1"))
        #expect(item.hasDetail == false, "a deleted workout's route must not come back")
        #expect(await seriesStore.loadIfAvailable("W1") == nil)
    }

    @Test("deleting an empty store is a no-op rather than an error")
    func deleteAllOnEmptyStore() async throws {
        #expect(try await makeStore().deleteAll() == 0)
        #expect(try await makeSeriesStore().deleteAll() == 0)
    }
}
