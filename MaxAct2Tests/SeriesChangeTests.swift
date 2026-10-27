import Foundation
import MaxActCore
import Testing

@testable import MaxAct2

/// Issue 38: the inspector reloads a workout's series when it's written, and a damaged one is
/// offered for download again instead of counting as downloaded with nothing to show.
@MainActor @Suite struct SeriesChangeTests {
    private func model() async -> AppModel {
        let suite = "SeriesChangeTests"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let model = AppModel.inMemoryFallback(settings: AppSettings(defaults: defaults, tokenStore: InMemoryHAETokenStore()), seedCount: 40,
                                              resolvesPlaces: false, stravaSecrets: InMemorySecretStore())
        await model.load()
        return model
    }

    /// The observer hops to the main actor in a task of its own; give it a moment.
    private func eventually(_ condition: () -> Bool) async {
        for _ in 0..<200 where !condition() { try? await Task.sleep(for: .milliseconds(10)) }
    }

    @Test func savingASeriesBumpsItsRevision() async throws {
        let model = await model()
        let item = try #require(model.items.first { $0.hasDetail })
        let series = try #require(await model.seriesStore.loadIfAvailable(item.id))
        let before = model.seriesRevisions[item.id] ?? 0

        try await model.seriesStore.save(series)
        await eventually { (model.seriesRevisions[item.id] ?? 0) > before }
        #expect((model.seriesRevisions[item.id] ?? 0) > before)
    }

    @Test func aDamagedSeriesIsOfferedForDownloadAgain() async throws {
        let model = await model()
        let item = try #require(model.items.first { $0.hasDetail })
        let url = await model.seriesStore.fileURL(for: item.id)
        let intact = try Data(contentsOf: url)
        try intact.prefix(intact.count / 3).write(to: url)

        #expect(await model.seriesStore.loadIfAvailable(item.id) == nil)
        await eventually { model.items.first { $0.id == item.id }?.hasDetail == false }
        #expect(model.items.first { $0.id == item.id }?.hasDetail == false)
    }
}
