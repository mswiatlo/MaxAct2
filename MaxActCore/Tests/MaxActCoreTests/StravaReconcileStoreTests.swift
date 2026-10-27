import Foundation
import Testing

@testable import MaxActCore

/// The store's half of noticing activities deleted on Strava.
@Suite struct StravaReconcileStoreTests {
    private let day: TimeInterval = 86_400
    private let base = Date(timeIntervalSince1970: 1_790_000_000)

    private func store() throws -> WorkoutStore {
        try inMemoryStore()
    }

    private func ingested(_ id: String, daysIn: Double) -> IngestedWorkout {
        let start = base.addingTimeInterval(daysIn * day)
        return IngestedWorkout(
            workout: Workout(id: id, kind: .cycling, start: start, end: start.addingTimeInterval(1800),
                             duration: 1800),
            series: WorkoutSeries(workoutID: id)
        )
    }

    @Test("a synced workout absent from the listing is a candidate; listed or unsynced ones aren't")
    func candidates() async throws {
        let store = try store()
        try await store.upsert([ingested("GONE", daysIn: 1), ingested("THERE", daysIn: 2),
                                ingested("LOCAL", daysIn: 3), ingested("WATCH", daysIn: 4)])
        try await store.setStravaState(.uploaded, activityID: 100, for: "GONE")
        try await store.setStravaState(.uploaded, activityID: 200, for: "THERE")
        try await store.markAlreadyOnStrava(["WATCH": 400])

        let span = DateInterval(start: base, end: base.addingTimeInterval(10 * day))
        let missing = try await store.syncedActivities(missingFrom: [200, 400], startingWithin: span)
        #expect(missing == [100: "GONE"])
    }

    @Test("outside the listed window, absence means nothing")
    func onlyWithinSpan() async throws {
        // The upload pre-check lists only the selection's dates. A synced workout from another
        // month isn't in that listing, and must not be nominated for a lookup.
        let store = try store()
        try await store.upsert([ingested("EARLY", daysIn: 1), ingested("LATE", daysIn: 30)])
        try await store.setStravaState(.uploaded, activityID: 100, for: "EARLY")
        try await store.setStravaState(.uploaded, activityID: 300, for: "LATE")

        let selectionOnly = DateInterval(start: base.addingTimeInterval(29 * day),
                                         end: base.addingTimeInterval(31 * day))
        let missing = try await store.syncedActivities(missingFrom: [], startingWithin: selectionOnly)
        #expect(missing == [300: "LATE"])
    }

    @Test("a deleted activity returns its workout to not-uploaded, keeping its tags")
    func markRemoved() async throws {
        let store = try store()
        try await store.upsert([ingested("A", daysIn: 1)])
        try await store.setStravaState(.uploaded, activityID: 100, uploadID: 9, for: "A")
        try await store.addTag("Commute", to: ["A"])   // also leaves a flag push pending

        #expect(try await store.markRemovedFromStrava(["A"]) == 1)
        let item = try #require(try await store.item(id: "A"))
        #expect(item.stravaState == .notUploaded)
        #expect(item.stravaActivityID == nil, "the link would lead to a dead activity")
        #expect(!item.stravaFlagsPending, "nothing left to push the flag to")
        #expect(item.tags == ["Commute"], "tags are local and still true of the ride")
        #expect(try await store.pendingStravaFlags().isEmpty)

        // Idempotent: it's no longer on Strava, so a second pass changes nothing.
        #expect(try await store.markRemovedFromStrava(["A"]) == 0)
    }

    @Test("once reset, the workout can be matched again — say, re-uploaded by the watch")
    func rematchAfterRemoval() async throws {
        let store = try store()
        try await store.upsert([ingested("A", daysIn: 1)])
        try await store.setStravaState(.uploaded, activityID: 100, for: "A")
        try await store.markRemovedFromStrava(["A"])

        #expect(try await store.markAlreadyOnStrava(["A": 555]) == 1)
        #expect(try await store.item(id: "A")?.stravaActivityID == 555)
    }
}
