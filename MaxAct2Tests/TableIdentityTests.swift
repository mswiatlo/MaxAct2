import Foundation
import MaxActCore
import Testing

@testable import MaxAct2

/// Issue 44: the table is built afresh only when an update would insert many rows at once.
@MainActor @Suite struct TableIdentityTests {
    @Test func onlyABigInsertionRebuildsTheTable() async {
        let suite = "TableIdentityTests"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let model = AppModel.inMemoryFallback(settings: AppSettings(defaults: defaults), seedCount: 40,
                                              resolvesPlaces: false, stravaSecrets: InMemorySecretStore())
        await model.load()
        model.searchText = ""   // the rows on screen: all 40
        let start = model.tableIdentity

        model.searchText = "Hiking"          // 40 → 6: rows leave, none arrive
        #expect(model.tableIdentity == start)
        model.searchText = "Hikin"           // same 6
        #expect(model.tableIdentity == start)
        model.searchText = ""                // 6 → 40: 34 arrive at once
        #expect(model.tableIdentity == start + 1)
        model.sidebarSelection = .filter(.withRoute)   // 40 → 5
        #expect(model.tableIdentity == start + 1)
        model.sidebarSelection = .filter(.all)         // 5 → 40
        #expect(model.tableIdentity == start + 2)
    }
}
