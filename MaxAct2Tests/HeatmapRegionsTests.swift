import Foundation
import MaxActCore
import Testing

@testable import MaxAct2

/// Issue 41: the heatmap's places are cached, and the cache must never go stale.
@MainActor @Suite struct HeatmapRegionsTests {
    private func model() async -> AppModel {
        let suite = "HeatmapRegionsTests"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let model = AppModel.inMemoryFallback(settings: AppSettings(defaults: defaults), seedCount: 40,
                                              resolvesPlaces: false, stravaSecrets: InMemorySecretStore())
        await model.load()
        await model.loadRouteSketches()
        return model
    }

    @Test func aRenamedPlaceIsWorkedOutAgain() async throws {
        let model = await model()
        let sketches = Array(model.routeSketches.values).sorted { $0.workoutID < $1.workoutID }
        try #require(!sketches.isEmpty)
        #expect(model.heatmapRegions(sketches, placeNames: [:]).first?.name == "Unnamed place")

        let named = Dictionary(uniqueKeysWithValues: sketches.map { ($0.workoutID, "Vancouver BC") })
        #expect(model.heatmapRegions(sketches, placeNames: named).first?.name == "Vancouver BC")
    }

    @Test func fewerRoutesAreWorkedOutAgain() async throws {
        let model = await model()
        let sketches = Array(model.routeSketches.values).sorted { $0.workoutID < $1.workoutID }
        try #require(sketches.count > 1)
        #expect(model.heatmapRegions(sketches, placeNames: [:]).first?.count == sketches.count)
        #expect(model.heatmapRegions(Array(sketches.dropFirst()), placeNames: [:]).first?.count == sketches.count - 1)
    }
}
