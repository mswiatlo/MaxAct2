import Foundation
import MaxActCore
import Testing

@testable import MaxAct2

/// Issue 40: a Keychain that can't be read used to look exactly like "not connected".
@MainActor @Suite struct SilentFailureTests {
    /// A store whose reads fail the way a refused or locked Keychain does.
    actor RefusingSecretStore: AppSecretStore {
        func credentials() async -> StravaCredentials? { nil }
        func tokens() async -> StravaTokens? { nil }
        func save(tokens: StravaTokens?) async throws {}
        func save(credentials: StravaCredentials?) async throws {}
        func readProblem() async -> String? { "Keychain error -25308: User interaction is not allowed." }
    }

    private func model(secrets: any AppSecretStore) -> AppModel {
        let suite = "SilentFailureTests"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return AppModel.inMemoryFallback(settings: AppSettings(defaults: defaults, tokenStore: InMemoryHAETokenStore()), resolvesPlaces: false,
                                         stravaSecrets: secrets)
    }

    @Test func anUnreadableKeychainIsSaidSoRatherThanLookingDisconnected() async {
        let model = model(secrets: RefusingSecretStore())
        await model.refreshStravaConnection()
        #expect(!model.isStravaConnected)
        #expect(model.stravaReadProblem?.contains("-25308") == true)
    }

    @Test func anEmptyStoreIsSimplyNotConnected() async {
        let model = model(secrets: InMemorySecretStore())
        await model.refreshStravaConnection()
        #expect(model.stravaReadProblem == nil)
    }

    @Test func aFailedChangeIsShown() {
        let model = model(secrets: InMemorySecretStore())
        model.reportFailedChange("Couldn't add the tag \"commute\"", StoreWriteFailed())
        #expect(model.loadError == "Couldn't add the tag \"commute\": the library couldn't be written")
    }
}
