import Foundation

/// The user's own Strava API application. Supplied by them, never shipped: Strava's OAuth has no
/// PKCE, so the secret is required for the token exchange and a bundled one would be extractable.
public struct StravaCredentials: Codable, Sendable, Equatable {
    public let clientID: String
    public let clientSecret: String

    public init(clientID: String, clientSecret: String) {
        self.clientID = clientID.trimmingCharacters(in: .whitespacesAndNewlines)
        self.clientSecret = clientSecret.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public var isComplete: Bool { !clientID.isEmpty && !clientSecret.isEmpty }
}

public struct StravaTokens: Codable, Sendable, Equatable {
    public let accessToken: String
    public let refreshToken: String
    public let expiresAt: Date
    public let athleteName: String?

    public init(accessToken: String, refreshToken: String, expiresAt: Date, athleteName: String? = nil) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
        self.athleteName = athleteName
    }

    /// Refresh a little early, so a token can't expire between being checked and being used.
    public func isFresh(at now: Date) -> Bool { expiresAt.timeIntervalSince(now) > 300 }
}

/// Where tokens and credentials live. The app backs this with the Keychain; tests use memory.
public protocol StravaSecretStore: Sendable {
    func credentials() async -> StravaCredentials?
    func tokens() async -> StravaTokens?
    func save(tokens: StravaTokens?) async throws
}

public enum StravaError: Error, Sendable, Equatable, CustomStringConvertible {
    /// No client ID and secret entered yet.
    case notConfigured
    /// Configured but never authorised, or the user revoked access.
    case notAuthorized
    /// Strava refused the token, even after a refresh.
    case authorizationRejected(String)
    case rateLimited(until: Date)
    case http(status: Int, message: String)
    case invalidResponse(String)

    public var description: String {
        switch self {
        case .notConfigured: "Strava isn't set up — add your API application's client ID and secret in Settings."
        case .notAuthorized: "Not connected to Strava. Connect in Settings."
        case .authorizationRejected(let detail): "Strava rejected the connection (\(detail)). Reconnect in Settings."
        case .rateLimited(let until): "Strava's rate limit was reached; uploads resume at \(until.formatted(date: .omitted, time: .shortened))."
        case .http(let status, let message): "Strava returned \(status): \(message)"
        case .invalidResponse(let detail): "Unexpected response from Strava: \(detail)"
        }
    }
}

/// Strava's `Upload` model, as documented in `swagger/upload.json`.
public struct StravaUploadResponse: Decodable, Sendable, Equatable {
    public let id: Int
    public let externalID: String?
    public let error: String?
    public let status: String?
    public let activityID: Int?

    enum CodingKeys: String, CodingKey {
        case id, error, status
        case externalID = "external_id"
        case activityID = "activity_id"
    }

    public init(id: Int, externalID: String? = nil, error: String? = nil, status: String? = nil,
                activityID: Int? = nil) {
        self.id = id
        self.externalID = externalID
        self.error = error
        self.status = status
        self.activityID = activityID
    }

    public enum Outcome: Sendable, Equatable {
        /// Accepted, still processing. **Not success** — the activity doesn't exist yet.
        case processing
        case ready(activityID: Int)
        /// Strava already has this workout. The desired end state holds, so it isn't a failure.
        case duplicate(activityID: Int?)
        case failed(String)
    }

    public var outcome: Outcome {
        if let error, !error.isEmpty {
            if let range = error.range(of: "duplicate of", options: .caseInsensitive) {
                return .duplicate(activityID: Self.firstNumber(in: error[range.upperBound...]))
            }
            return .failed(error)
        }
        if let activityID { return .ready(activityID: activityID) }
        return .processing
    }

    /// The activity id after "duplicate of", which Strava writes either as plain text
    /// ("duplicate of activity 123") or inside a link ("duplicate of <a href='/activities/123'>").
    /// Searching only *after* the phrase matters: the error starts with the uploaded file's name,
    /// which may itself contain digits.
    static func firstNumber(in text: Substring) -> Int? {
        let digits = text.drop { !$0.isNumber }.prefix { $0.isNumber }
        return Int(digits)
    }
}

extension ActivityKind {
    /// Strava's `sport_type` for this activity.
    public var stravaSportType: String {
        switch self {
        case .running: "Run"
        case .walking: "Walk"
        case .hiking: "Hike"
        case .cycling, .indoorCycling: "Ride"
        case .swimming: "Swim"
        case .rowing: "Rowing"
        case .elliptical: "Elliptical"
        case .strengthTraining: "WeightTraining"
        case .yoga: "Yoga"
        case .functionalTraining, .other: "Workout"
        }
    }

    /// Whether the uploaded file alone gets the sport right.
    ///
    /// The upload API takes no activity type — it is inferred from the TCX `Sport` attribute,
    /// which only knows Running, Biking and Other. So everything except runs and rides needs a
    /// follow-up `PUT sport_type`, or a walk lands on Strava as a generic workout. Measured against
    /// the published spec (2026-10-07): `POST /uploads` documents `file`, `name`, `description`,
    /// `trainer`, `commute`, `data_type` and `external_id`, and nothing else.
    public var stravaNeedsSportCorrection: Bool {
        switch self {
        case .running, .cycling, .indoorCycling: false
        default: true
        }
    }
}

/// The two activity flags Strava exposes, and the only tags that travel to it.
public struct StravaFlags: Sendable, Equatable {
    public var commute: Bool
    public var trainer: Bool

    public init(commute: Bool, trainer: Bool) {
        self.commute = commute
        self.trainer = trainer
    }

    public init(tags: [String]) {
        commute = tags.contains(WorkoutTag.commute)
        trainer = tags.contains(WorkoutTag.trainer)
    }
}

/// The writable fields of Strava's `UpdatableActivity` that MaxAct uses. `nil` means "leave alone".
public struct StravaActivityUpdate: Sendable, Equatable {
    public var sportType: String?
    public var commute: Bool?
    public var trainer: Bool?
    /// Strava's "Mute Activity": `hide_from_home`, documented as *"Whether this activity is
    /// muted"*. Not accepted at upload, so it can only be set this way.
    public var muted: Bool?

    public init(sportType: String? = nil, commute: Bool? = nil, trainer: Bool? = nil, muted: Bool? = nil) {
        self.sportType = sportType
        self.commute = commute
        self.trainer = trainer
        self.muted = muted
    }

    public var isEmpty: Bool { sportType == nil && commute == nil && trainer == nil && muted == nil }

    var json: [String: Any] {
        var body: [String: Any] = [:]
        if let sportType { body["sport_type"] = sportType }
        if let commute { body["commute"] = commute }
        if let trainer { body["trainer"] = trainer }
        if let muted { body["hide_from_home"] = muted }
        return body
    }
}
