import Foundation
import MaxActCore
import Testing

@testable import MaxAct2

/// Issue 39: one job at a time against the phone or Strava, and Stop that really stops.
@MainActor @Suite struct JobTests {
    typealias PretendPhone = SyncEverythingTests.PretendPhone

    private func model(seed: Int? = nil) async -> AppModel {
        let suite = "JobTests"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let model = AppModel.inMemoryFallback(settings: AppSettings(defaults: defaults, tokenStore: InMemoryHAETokenStore()), seedCount: seed,
                                              resolvesPlaces: false, stravaSecrets: InMemorySecretStore())
        await model.load()
        return model
    }

    /// Nine weeks of runs, each week's request taking a tenth of a second.
    private func slowSync(_ model: AppModel) -> PretendPhone {
        let phone = PretendPhone(dates: SyncEverythingTests.history, timeoutAbove: 1000, delay: .milliseconds(100))
        model.startSync(from: SyncEverythingTests.end.addingTimeInterval(-60 * 86_400), to: SyncEverythingTests.end,
                        source: HAEWorkoutSource(client: MCPClient(transport: phone, token: "t")))
        return phone
    }

    private func untilTheFirstWeek(_ phone: PretendPhone) async {
        for _ in 0..<200 where await phone.listCalls == 0 { try? await Task.sleep(for: .milliseconds(10)) }
    }

    @Test func stopWaitsForTheJobAndEndsIdle() async {
        let model = await model()
        let phone = slowSync(model)
        await untilTheFirstWeek(phone)

        model.cancelSync()
        // Still running until the week in flight is done, so nothing can start alongside it.
        #expect(model.syncStatus.isRunning)
        #expect(model.isStopping)
        #expect(model.startJob(.listing, { .idle }) == nil)

        await model.waitForJob()
        // Idle — not a "Synced N" that appears after Stop.
        #expect(model.syncStatus == .idle, "\(model.syncStatus)")
        #expect(!model.isStopping)
        #expect(await phone.listCalls < 9, "stopped early")
    }

    @Test func aSecondStartInTheSameTurnIsRefusedAndStopStillStopsTheFirst() async {
        let model = await model()
        // Both on one phone, as the user's two clicks would be.
        let phone = PretendPhone(dates: SyncEverythingTests.history, timeoutAbove: 1000, delay: .milliseconds(100))
        let source = HAEWorkoutSource(client: MCPClient(transport: phone, token: "t"))
        let start = SyncEverythingTests.end.addingTimeInterval(-60 * 86_400)
        model.startSync(from: start, to: SyncEverythingTests.end, source: source)
        model.startSync(from: start, to: SyncEverythingTests.end, source: source)
        await untilTheFirstWeek(phone)
        model.cancelSync()
        await model.waitForJob()
        #expect(model.syncStatus == .idle, "\(model.syncStatus)")
        #expect(await phone.connections == 1, "only one job talked to the phone")
    }

    @Test func deletingIsRefusedWhileAJobRuns() async {
        let model = await model(seed: 10)
        let phone = slowSync(model)
        await untilTheFirstWeek(phone)
        await model.deleteAllData()
        #expect(model.items.count >= 10)
        model.cancelSync()
        await model.waitForJob()
    }
}
