import Foundation
import MaxActCore
import Testing

@testable import MaxAct2

/// Issue 43: the sidebar's filters had no unit test, only the UI test that clicks them.
@MainActor @Suite struct WorkoutFilterTests {
    @Test func theSeedsFiltersCountWhatTheySay() async throws {
        let suite = "WorkoutFilterTests"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let model = AppModel.inMemoryFallback(settings: AppSettings(defaults: defaults), seedCount: 40,
                                              resolvesPlaces: false, stravaSecrets: InMemorySecretStore())
        await model.load()
        func count(_ filter: WorkoutFilter) -> Int { model.items.filter(filter.matches).count }

        // The seed's six-kind cycle: indoor rides and strength sessions are indoor (13 of 40);
        // every fifth outdoor workout has a route (5); nothing has been near Strava.
        #expect(count(.all) == 40)
        #expect(count(.indoor) == 13)
        #expect(count(.withRoute) == 5)
        #expect(count(.notOnStrava) == 40)
        #expect(count(.uploadFailed) == 0)

        try await model.store.setStravaState(.failed(reason: "no"), for: "SEED-1")
        try await model.store.setStravaState(.uploaded, activityID: 1, for: "SEED-2")
        await model.refreshItems()
        #expect(count(.uploadFailed) == 1)
        #expect(count(.notOnStrava) == 39)
        #expect(SidebarSelection.kind(ActivityKind.cycling.storageKey).matches(try #require(model.items.first { $0.id == "SEED-0" })))
    }
}
