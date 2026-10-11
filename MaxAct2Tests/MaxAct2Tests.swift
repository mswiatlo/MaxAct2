import Foundation
import Testing

@testable import MaxAct2

/// Phase 0 smoke tests. These exist to prove the test bundle is hosted in the app correctly —
/// `@testable import MaxAct2` only resolves when TEST_HOST and BUNDLE_LOADER are wired up, so a
/// regression in that wiring fails the build rather than silently running zero tests.
@Suite struct AppHostingTests {
    @Test func testBundleIsHostedInTheApp() throws {
        let identifier = Bundle.main.bundleIdentifier
        #expect(identifier == "com.swiatlowski.MaxAct")
    }

    /// The host app recognises it's running tests, and so runs on throwaway in-memory stores.
    ///
    /// Without this the host was the *real* app: it opened the user's database and settings and
    /// read their Strava login from the Keychain — which, ad-hoc signed, raised a password prompt
    /// that then stopped the first UI test from bringing the app forward.
    @MainActor @Test func hostRunsIsolatedFromRealData() {
        #expect(MaxActApp.isHostingUnitTests)
        #expect(MaxActApp.isIsolatedForTesting)
    }

    @Test func appTypeIsVisibleToTests() {
        // Referencing an app type is what actually requires the bundle loader.
        #expect(String(describing: MaxActApp.self) == "MaxActApp")
    }
}
