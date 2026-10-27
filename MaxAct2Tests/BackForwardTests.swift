import Foundation
import MaxActCore
import Testing

@testable import MaxAct2

/// Issue 32: Back and Forward retrace jumps (`AppModel.reveal`), restoring the view a jump left.
@MainActor @Suite struct BackForwardTests {
    private func model() async -> AppModel {
        let suite = "BackForwardTests"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let model = AppModel.inMemoryFallback(settings: AppSettings(defaults: defaults, tokenStore: InMemoryHAETokenStore()), seedCount: 40,
                                              resolvesPlaces: false, stravaSecrets: InMemorySecretStore())
        await model.load()
        return model
    }

    @Test func backReturnsToWhereTheJumpStartedAndForwardGoesAgain() async throws {
        let model = await model()
        let ids = model.visibleItems.map(\.id)
        model.selection = [ids[0]]
        #expect(!model.canGoBack)

        model.reveal(ids[5])
        model.reveal(ids[9])
        #expect(model.selection == [ids[9]])

        model.goBack()
        #expect(model.selection == [ids[5]])
        model.goBack()
        #expect(model.selection == [ids[0]])
        #expect(!model.canGoBack)

        model.goForward()
        #expect(model.selection == [ids[5]])
        #expect(model.canGoForward)
    }

    /// Only jumps make history: clicking around the table doesn't (decided with the user).
    @Test func ordinarySelectionChangesDontAddHistory() async {
        let model = await model()
        let ids = model.visibleItems.map(\.id)
        model.selection = [ids[0]]
        model.selection = [ids[1]]
        model.selection = [ids[2]]
        #expect(!model.canGoBack)

        model.reveal(ids[7])
        model.selection = [ids[8]]   // a click after the jump
        model.goBack()
        #expect(model.selection == [ids[2]], "Back returns to where the jump started")
    }

    /// A jump that had to clear the search and filter puts them back on Back.
    @Test func backRestoresTheSearchAndFilterAJumpCleared() async throws {
        let model = await model()
        let running = try #require(model.items.first { $0.workout.kind == .running })
        let other = try #require(model.items.first { $0.workout.kind != .running })
        model.sidebarSelection = .kind(ActivityKind.running.storageKey)
        model.searchText = "Running"
        model.selection = [running.id]

        model.reveal(other.id)
        #expect(model.sidebarSelection == .filter(.all))
        #expect(model.searchText.isEmpty)

        model.goBack()
        #expect(model.sidebarSelection == .kind(ActivityKind.running.storageKey))
        #expect(model.searchText == "Running")
        #expect(model.selection == [running.id])
    }

    @Test func aNewJumpClearsForward() async {
        let model = await model()
        let ids = model.visibleItems.map(\.id)
        model.selection = [ids[0]]
        model.reveal(ids[3])
        model.goBack()
        #expect(model.canGoForward)
        model.reveal(ids[4])
        #expect(!model.canGoForward)
    }

    /// Jumping to the workout already shown isn't a move.
    @Test func jumpingToTheCurrentWorkoutAddsNothing() async {
        let model = await model()
        let ids = model.visibleItems.map(\.id)
        model.selection = [ids[0]]
        model.reveal(ids[0])
        #expect(!model.canGoBack)
    }
}
