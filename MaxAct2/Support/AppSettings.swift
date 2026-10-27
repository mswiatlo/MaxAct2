import Foundation
import MaxActCore
import Observation

/// User settings, persisted in `UserDefaults` — except Health Auto Export's token, which is in the
/// Keychain (issue 48; see `KeychainHAETokenStore`).
///
/// Named for the app rather than for sync because it now carries appearance too.
@Observable
final class AppSettings {
    /// Injected rather than reaching for `.standard`, so UI tests can be handed a throwaway
    /// domain. They type into these fields, and one test run overwriting the real token was
    /// enough to make this worth doing properly.
    @ObservationIgnored private let defaults: UserDefaults

    var host: String {
        didSet { defaults.set(host, forKey: "syncHost") }
    }
    var token: String {
        didSet {
            guard token != oldValue else { return }
            do {
                try tokenStore.save(token: token)
                tokenSaveProblem = nil
            } catch {
                tokenSaveProblem = String(describing: error)
            }
        }
    }
    @ObservationIgnored private let tokenStore: any HAETokenStore
    /// Why the token couldn't be kept, shown under the field.
    private(set) var tokenSaveProblem: String?

    /// HTTPS to the phone, trusting only `pinnedCA` (issue 48). Off means plain HTTP, which anyone
    /// on the network can read — the token included.
    var usesHTTPS: Bool {
        didSet { defaults.set(usesHTTPS, forKey: "syncUsesHTTPS") }
    }

    /// The CA Health Auto Export exported, as DER. In the preferences rather than the Keychain:
    /// a certificate is public.
    var pinnedCA: PinnedCA? {
        didSet { defaults.set(pinnedCA?.der, forKey: "syncPinnedCA") }
    }

    /// Mute activities MaxAct uploads (Strava's `hide_from_home`), keeping them off followers'
    /// home feeds. On by default: uploading years of old workouts at once is the main use, and
    /// that shouldn't flood anyone's feed. Costs one extra write per run or ride; walks and hikes
    /// already need a post-upload `PUT` for their sport, so for them it's free.
    var muteStravaUploads: Bool {
        didSet { defaults.set(muteStravaUploads, forKey: "muteStravaUploads") }
    }

    /// Training load's heart-rate profile (issue 15). Zero, or `nil` for the curve, means not set:
    /// there are no safe defaults — resting heart rate isn't in the data at all, and the curve is
    /// the user's choice, never inferred.
    var restingHeartRate: Int {
        didSet { defaults.set(restingHeartRate, forKey: "restingHeartRate") }
    }
    var maximumHeartRate: Int {
        didSet { defaults.set(maximumHeartRate, forKey: "maximumHeartRate") }
    }
    var trimpCurve: HeartRateProfile.Curve? {
        didSet { defaults.set(trimpCurve?.rawValue, forKey: "trimpCurve") }
    }

    var heartRateProfile: HeartRateProfile? {
        guard let trimpCurve else { return nil }
        return HeartRateProfile(resting: Double(restingHeartRate), maximum: Double(maximumHeartRate), curve: trimpCurve)
    }

    /// Whether the welcome sheet has been seen (or dismissed). Set on its first close.
    var hasSeenWelcome: Bool {
        didSet { defaults.set(hasSeenWelcome, forKey: "hasSeenWelcome") }
    }

    /// The sidebar choice and table sort, remembered between launches (Phase 8). Stored here so
    /// UI tests, which get a throwaway defaults domain, can never disturb the real ones.
    var sidebarSelectionKey: String? {
        didSet { defaults.set(sidebarSelectionKey, forKey: "sidebarSelection") }
    }
    var tableSortKey: String? {
        didSet { defaults.set(tableSortKey, forKey: "tableSort") }
    }

    /// Whether stored workouts have been checked for heart rate the workout export averaged away
    /// (Apple Workout app recordings), and the sparse ones marked for re-download. Once per library.
    var hasRepairedSparseHeartRate: Bool {
        didSet { defaults.set(hasRepairedSparseHeartRate, forKey: "hasRepairedSparseHeartRate") }
    }

    /// Whether stored routes Health Auto Export sent only part of have been filled from Strava
    /// (issue 19). Set once a pass completes with Strava connected.
    var hasFilledIncompleteRoutes: Bool {
        didSet { defaults.set(hasFilledIncompleteRoutes, forKey: "hasFilledIncompleteRoutes") }
    }

    /// Whether workouts repaired before repairs were recorded have been marked for re-download,
    /// so the re-download records them (issue 22). Once per library.
    var hasMarkedRepairsForRedownload: Bool {
        didSet { defaults.set(hasMarkedRepairsForRedownload, forKey: "hasMarkedRepairsForRedownload") }
    }

    /// Colour of route tracks on thumbnails and the detail map.
    var routeColor: RouteColor {
        didSet { defaults.set(routeColor.rawValue, forKey: "routeColor") }
    }

    /// - Parameter tokenStore: no default, so nothing — a test least of all — reaches the real
    ///   Keychain without saying so.
    init(defaults: UserDefaults = .standard, tokenStore: any HAETokenStore) {
        self.defaults = defaults
        self.tokenStore = tokenStore
        host = defaults.string(forKey: "syncHost") ?? ""
        token = Self.migrateToken(from: defaults, to: tokenStore)
        // New setups start on HTTPS; one that already syncs over HTTP stays on it until changed.
        usesHTTPS = defaults.object(forKey: "syncUsesHTTPS") as? Bool ?? (defaults.string(forKey: "syncHost") ?? "").isEmpty
        pinnedCA = defaults.data(forKey: "syncPinnedCA").flatMap { try? PinnedCA(contents: $0) }
        routeColor = RouteColor(storageKey: defaults.string(forKey: "routeColor"))
        muteStravaUploads = defaults.object(forKey: "muteStravaUploads") as? Bool ?? true
        hasSeenWelcome = defaults.bool(forKey: "hasSeenWelcome")
        restingHeartRate = defaults.integer(forKey: "restingHeartRate")
        maximumHeartRate = defaults.integer(forKey: "maximumHeartRate")
        trimpCurve = defaults.string(forKey: "trimpCurve").flatMap(HeartRateProfile.Curve.init(rawValue:))
        sidebarSelectionKey = defaults.string(forKey: "sidebarSelection")
        tableSortKey = defaults.string(forKey: "tableSort")
        hasRepairedSparseHeartRate = defaults.bool(forKey: "hasRepairedSparseHeartRate")
        hasFilledIncompleteRoutes = defaults.bool(forKey: "hasFilledIncompleteRoutes")
        hasMarkedRepairsForRedownload = defaults.bool(forKey: "hasMarkedRepairsForRedownload")
    }

    /// The token from the Keychain; or, the first time, moved there from the preferences, where
    /// it used to be. Removed from the preferences only once the Keychain has it.
    private static func migrateToken(from defaults: UserDefaults, to store: any HAETokenStore) -> String {
        if let stored = store.token() { return stored }
        guard let old = defaults.string(forKey: "syncToken") else { return "" }
        do {
            try store.save(token: old)
            defaults.removeObject(forKey: "syncToken")
        } catch {
            // Left where it was, and tried again next launch.
        }
        return old
    }

    /// The address as actually parsed, with the scheme the HTTPS setting chooses, or `nil` if it
    /// can't be parsed. Shown in the UI so there is no question about what will be contacted.
    var endpoint: MCPEndpoint? { MCPEndpoint(host)?.with(https: usesHTTPS) }

    var isConfigured: Bool {
        endpoint != nil && !token.trimmingCharacters(in: .whitespaces).isEmpty && (!usesHTTPS || pinnedCA != nil)
    }

    func makeSource(timeout: TimeInterval = 600) -> HAEWorkoutSource? {
        guard isConfigured, let endpoint else { return nil }
        return HAEWorkoutSource(endpoint: endpoint, token: token.trimmingCharacters(in: .whitespaces),
                                timeout: timeout, pinnedCA: usesHTTPS ? pinnedCA?.certificate : nil)
    }
}
