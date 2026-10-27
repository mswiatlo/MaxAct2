import Foundation

/// What a value from outside — the phone, or Strava — must look like before the app keeps it
/// (issue 45). Anyone on the same Wi-Fi as an HTTP link can pretend to be the phone, so the
/// payload is untrusted: an id becomes a file name, and a number reaches `Int(…)`, which traps.
public enum InputLimits {
    /// HAE's ids are HealthKit UUIDs. Letters, digits and hyphens only, so an id can never
    /// name a path (`../../x`) or break a header.
    public static func isValidID(_ id: String) -> Bool {
        !id.isEmpty && id.count <= 64 && id.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
    }

    /// The longest workout kept: a week. Anything longer is a corrupt or forged entry.
    public static let longestWorkout: TimeInterval = 7 * 86_400

    /// The largest plausible magnitude in each canonical unit — far beyond any real workout, far
    /// below where arithmetic or `Int(…)` goes wrong.
    public static func ceiling(for dimension: Units.Dimension) -> Double {
        switch dimension {
        case .length: 1e7          // 10,000 km
        case .energy: 1e6          // kcal
        case .speed: 1_000         // m/s
        case .rate: 300            // bpm
        case .count: 1e7
        case .duration: longestWorkout
        }
    }

    /// `value` if finite and within ±`ceiling`, else `nil`.
    public static func plausible(_ value: Double?, within ceiling: Double) -> Double? {
        guard let value, value.isFinite, abs(value) <= ceiling else { return nil }
        return value
    }

    /// A file-name component for `id` that can't leave its folder: anything but letters, digits
    /// and hyphens is percent-encoded. Valid ids pass through unchanged, so existing files keep
    /// their names.
    public static func fileComponent(_ id: String) -> String {
        if isValidID(id) { return id }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-")
        return "x" + (id.addingPercentEncoding(withAllowedCharacters: allowed) ?? "invalid")
    }
}

/// A value from outside that's out of range for a field the workout can't do without.
public struct ImplausibleValueError: Error, Equatable, CustomStringConvertible {
    public let field: String
    public let value: String

    public var description: String { "implausible \(field): \(value)" }
}

extension Int {
    /// `value` as an `Int`, clamped rather than trapping: `Int(1e300)` and `Int(.nan)` crash the
    /// app, and once a bad value is stored it would on every launch (issue 45). NaN becomes 0.
    public init(saturating value: Double) {
        guard value.isFinite else { self = value.isNaN ? 0 : (value > 0 ? .max : .min); return }
        self = value >= Double(Int.max) ? .max : value <= Double(Int.min) ? .min : Int(value)
    }
}
