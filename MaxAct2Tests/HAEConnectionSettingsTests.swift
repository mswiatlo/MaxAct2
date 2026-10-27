import Foundation
import Security
import MaxActCore
import Testing

@testable import MaxAct2

/// Issue 48: the token moves to a secret store, and HTTPS needs a pinned CA before syncing.
@MainActor
struct HAEConnectionSettingsTests {
    private func defaults() -> UserDefaults {
        let name = "HAEConnectionSettingsTests-\(UUID())"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    @Test("a token in the preferences moves to the store, and leaves the preferences")
    func tokenMigrates() {
        let defaults = defaults()
        defaults.set("old-token", forKey: "syncToken")
        let store = InMemoryHAETokenStore()
        let settings = AppSettings(defaults: defaults, tokenStore: store)
        #expect(settings.token == "old-token")
        #expect(store.token() == "old-token")
        #expect(defaults.string(forKey: "syncToken") == nil)
    }

    @Test("a failed save leaves the token where it was")
    func failedMigrationKeepsTheToken() {
        let defaults = defaults()
        defaults.set("old-token", forKey: "syncToken")
        let settings = AppSettings(defaults: defaults, tokenStore: RefusingStore())
        #expect(settings.token == "old-token")
        #expect(defaults.string(forKey: "syncToken") == "old-token")
    }

    @Test("edits go to the store, never the preferences")
    func editsGoToTheStore() {
        let defaults = defaults()
        let store = InMemoryHAETokenStore()
        let settings = AppSettings(defaults: defaults, tokenStore: store)
        settings.token = "typed"
        #expect(store.token() == "typed")
        #expect(defaults.string(forKey: "syncToken") == nil)
        #expect(AppSettings(defaults: defaults, tokenStore: store).token == "typed")
    }

    @Test("HTTPS defaults on for a new setup and stays off for one already syncing")
    func httpsDefault() {
        #expect(AppSettings(defaults: defaults(), tokenStore: InMemoryHAETokenStore()).usesHTTPS)
        let existing = defaults()
        existing.set("10.0.0.5", forKey: "syncHost")
        #expect(!AppSettings(defaults: existing, tokenStore: InMemoryHAETokenStore()).usesHTTPS)
    }

    @Test("HTTPS without a CA isn't configured; the endpoint follows the setting")
    func httpsNeedsTheCA() {
        let settings = AppSettings(defaults: defaults(), tokenStore: InMemoryHAETokenStore(token: "t"))
        settings.host = "http://10.0.0.5"
        settings.usesHTTPS = true
        #expect(settings.endpoint?.url.absoluteString == "https://10.0.0.5:9000/mcp")
        #expect(!settings.isConfigured)
        #expect(settings.makeSource() == nil)
        settings.usesHTTPS = false
        #expect(settings.endpoint?.url.absoluteString == "http://10.0.0.5:9000/mcp")
        #expect(settings.isConfigured)
    }

    private final class RefusingStore: HAETokenStore {
        func token() -> String? { nil }
        func save(token: String?) throws { throw KeychainError(status: errSecInteractionNotAllowed) }
    }
}
