import Foundation

/// Strava's two rate-limit buckets, tracked from response headers.
///
/// | Bucket | 15-minute | Daily |
/// |---|---|---|
/// | Overall — every request | 200 | 2,000 |
/// | Read — every non-upload request | 100 | 1,000 |
///
/// The easy mistake is that **upload-status polls are `GET`s and spend the read bucket**, so an
/// eager polling loop throttles itself long before uploads run out. Every request spends the
/// overall bucket; reads spend both.
///
/// Usage is taken from `X-RateLimit-*` and `X-ReadRateLimit-*` whenever a response arrives —
/// Strava's count is authoritative, and other clients on the same app may be spending it too.
/// Between responses the budget counts locally and optimistically, so a burst of requests can't
/// all slip under a limit that the first response would have revealed.
///
/// Value type with time passed in, so every rule is testable without a clock.
public struct StravaRateLimit: Sendable, Equatable {
    public enum Kind: Sendable {
        /// Uploads and activity updates: spend the overall bucket only.
        case write
        /// Everything else, including upload-status polls: spend both buckets.
        case read
    }

    public struct Bucket: Sendable, Equatable {
        public var shortTermUsed: Int
        public var shortTermLimit: Int
        public var dailyUsed: Int
        public var dailyLimit: Int
    }

    public private(set) var overall = Bucket(shortTermUsed: 0, shortTermLimit: 200, dailyUsed: 0, dailyLimit: 2000)
    public private(set) var read = Bucket(shortTermUsed: 0, shortTermLimit: 100, dailyUsed: 0, dailyLimit: 1000)

    /// After a 429, nothing is sent before this.
    public private(set) var blockedUntil: Date?

    /// When the counts were last brought up to date, so a window boundary since then resets them.
    private var lastUpdated: Date?

    /// Requests held back from each limit. Responses arrive after requests leave, so running right
    /// up to the limit risks a 429 from a request already in flight.
    static let margin = 2

    public init() {}

    // MARK: - Asking

    /// When a request of this kind may go: `now` if there is room, otherwise the moment the
    /// exhausted window resets.
    public mutating func earliestStart(for kind: Kind, at now: Date) -> Date {
        rollOver(to: now)
        var start = now
        if let blockedUntil, blockedUntil > now { start = max(start, blockedUntil) }

        let buckets = kind == .read ? [overall, read] : [overall]
        for bucket in buckets {
            if bucket.dailyUsed >= bucket.dailyLimit - Self.margin {
                start = max(start, Self.nextMidnightUTC(after: now))
            } else if bucket.shortTermUsed >= bucket.shortTermLimit - Self.margin {
                start = max(start, Self.nextQuarterHour(after: now))
            }
        }
        return start
    }

    /// Records that a request is being sent, before its response says what it really cost.
    public mutating func spend(_ kind: Kind, at now: Date) {
        rollOver(to: now)
        overall.shortTermUsed += 1
        overall.dailyUsed += 1
        if kind == .read {
            read.shortTermUsed += 1
            read.dailyUsed += 1
        }
    }

    // MARK: - Learning

    /// Replaces local counts with Strava's own, from a response's headers. Header names are
    /// matched case-insensitively, since HTTP/2 lower-cases them.
    public mutating func record(headers: [String: String], at now: Date) {
        let lowered = Dictionary(headers.map { ($0.key.lowercased(), $0.value) }, uniquingKeysWith: { a, _ in a })
        if let usage = Self.pair(lowered["x-ratelimit-usage"]),
           let limit = Self.pair(lowered["x-ratelimit-limit"]) {
            overall = Bucket(shortTermUsed: usage.0, shortTermLimit: limit.0,
                             dailyUsed: usage.1, dailyLimit: limit.1)
        }
        if let usage = Self.pair(lowered["x-readratelimit-usage"]),
           let limit = Self.pair(lowered["x-readratelimit-limit"]) {
            read = Bucket(shortTermUsed: usage.0, shortTermLimit: limit.0,
                          dailyUsed: usage.1, dailyLimit: limit.1)
        }
        lastUpdated = now
    }

    /// A 429: wait for the next quarter hour, or midnight UTC if the response shows a daily
    /// limit is the one exhausted. A rejected request still counts against the daily limit.
    public mutating func recordThrottled(headers: [String: String], at now: Date) {
        record(headers: headers, at: now)
        let dailyExhausted = overall.dailyUsed >= overall.dailyLimit || read.dailyUsed >= read.dailyLimit
        blockedUntil = dailyExhausted ? Self.nextMidnightUTC(after: now) : Self.nextQuarterHour(after: now)
    }

    // MARK: - Windows

    /// Short-term windows reset on the quarter hour, the daily ones at midnight UTC. A count
    /// learned before a boundary means nothing after it.
    private mutating func rollOver(to now: Date) {
        defer { lastUpdated = now }
        guard let lastUpdated else { return }
        if Self.nextMidnightUTC(after: lastUpdated) <= now {
            overall.dailyUsed = 0
            read.dailyUsed = 0
        }
        if Self.nextQuarterHour(after: lastUpdated) <= now {
            overall.shortTermUsed = 0
            read.shortTermUsed = 0
        }
    }

    static func nextQuarterHour(after date: Date) -> Date {
        let quarter: TimeInterval = 15 * 60
        return Date(timeIntervalSince1970: (date.timeIntervalSince1970 / quarter).rounded(.down) * quarter + quarter)
    }

    static func nextMidnightUTC(after date: Date) -> Date {
        let day: TimeInterval = 86_400
        return Date(timeIntervalSince1970: (date.timeIntervalSince1970 / day).rounded(.down) * day + day)
    }

    /// `"36,1200"` → `(36, 1200)`.
    private static func pair(_ value: String?) -> (Int, Int)? {
        guard let parts = value?.split(separator: ",").map({ Int($0.trimmingCharacters(in: .whitespaces)) }),
              parts.count == 2, let first = parts[0], let second = parts[1]
        else { return nil }
        return (first, second)
    }
}
