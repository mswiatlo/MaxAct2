import Foundation
import MaxActCore
import SwiftUI
import Testing

@testable import MaxAct2

/// Phase 8: the sidebar choice and the table sort survive a relaunch; search and selection don't.
@MainActor @Suite struct RememberedStateTests {
    /// A fresh, throwaway defaults domain per test, never the real one.
    private func settings(_ name: String = #function) -> (AppSettings, UserDefaults) {
        let suite = "RememberedStateTests.\(name)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return (AppSettings(defaults: defaults, tokenStore: InMemoryHAETokenStore()), defaults)
    }

    private func model(_ settings: AppSettings) -> AppModel {
        AppModel.inMemoryFallback(settings: settings, resolvesPlaces: false, stravaSecrets: InMemorySecretStore())
    }

    @Test func sidebarChoicesRoundTrip() {
        let choices: [SidebarSelection] = [.filter(.all), .filter(.uploadFailed), .kind("cycling"), .tag("With Kid"), .statistics]
        for choice in choices {
            #expect(SidebarSelection(storageKey: choice.storageKey) == choice, "\(choice)")
        }
        #expect(SidebarSelection(storageKey: "filter:nonsense") == nil)
        #expect(SidebarSelection(storageKey: nil) == nil)
    }

    @Test func sortOrdersRoundTrip() {
        for key in ["date:asc", "date:desc", "activity:asc", "distance:desc", "pace:asc", "heartRate:desc"] {
            let order = TableSort.order(storageKey: key)
            #expect(order != nil, "\(key)")
            #expect(TableSort.storageKey(for: order ?? []) == key)
        }
        #expect(TableSort.order(storageKey: "place:asc") == nil)
    }

    @Test func aNewModelRestoresWhatTheLastOneLeft() {
        let (settings, defaults) = settings()
        let first = model(settings)
        first.sidebarSelection = .statistics
        first.sortOrder = TableSort.order(storageKey: "distance:desc")!
        first.searchText = "commute"

        let second = model(AppSettings(defaults: defaults, tokenStore: InMemoryHAETokenStore()))
        #expect(second.sidebarSelection == .statistics)
        #expect(TableSort.storageKey(for: second.sortOrder) == "distance:desc")
        #expect(second.searchText.isEmpty, "Search isn't remembered.")
    }

    @Test func aRememberedTagThatsGoneFallsBackToAllWorkouts() async {
        let (settings, _) = settings()
        settings.sidebarSelectionKey = "tag:Vanished"
        let model = model(settings)
        #expect(model.sidebarSelection == .tag("Vanished"))
        await model.load()   // an empty library: no such tag
        #expect(model.sidebarSelection == .filter(.all))
    }
}
