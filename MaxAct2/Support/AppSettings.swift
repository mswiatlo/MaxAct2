import Foundation
import MaxActCore
import Observation

/// User settings, persisted in `UserDefaults`.
///
/// Named for the app rather than for sync because it now carries appearance too. The bearer token
/// is *not* a long-lived secret — it is regenerated from Health Auto Export's Server screen at
/// will, and only grants access to a server that must be foregrounded on an unlocked phone on the
/// same LAN. Strava's client secret in Phase 8 is a different matter and goes in the Keychain.
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
        didSet { defaults.set(token, forKey: "syncToken") }
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

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        host = defaults.string(forKey: "syncHost") ?? ""
        token = defaults.string(forKey: "syncToken") ?? ""
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

    /// The address as actually parsed, or `nil` if it can't be. Shown in the UI so there is no
    /// question about what will be contacted.
    var endpoint: MCPEndpoint? { MCPEndpoint(host) }

    var isConfigured: Bool {
        endpoint != nil && !token.trimmingCharacters(in: .whitespaces).isEmpty
    }

    func makeSource(timeout: TimeInterval = 600) -> HAEWorkoutSource? {
        guard let endpoint, !token.isEmpty else { return nil }
        return HAEWorkoutSource(endpoint: endpoint, token: token.trimmingCharacters(in: .whitespaces),
                                timeout: timeout)
    }
}
