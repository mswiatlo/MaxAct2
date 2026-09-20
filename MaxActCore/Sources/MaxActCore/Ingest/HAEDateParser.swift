import Foundation

/// Parses Health Auto Export's `yyyy-MM-dd HH:mm:ss Z` timestamps.
///
/// `DateFormatter` is expensive to create and not cheap to use, and a single sync decodes hundreds
/// of thousands of these (a 3.5 h hike alone carries 12,645 route points), so one formatter is
/// reused and results are memoised — series timestamps repeat heavily across a payload.
///
/// The UTC offset in the string is always honoured. Pinning a time zone instead would put workouts
/// recorded while travelling on the wrong day.
public final class HAEDateParser {
    private let formatter: DateFormatter
    private var cache: [String: Date] = [:]

    public init() {
        formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = MaxActCore.haeDateFormat
    }

    public struct MalformedDateError: Error, Equatable, CustomStringConvertible {
        public let field: String
        public let value: String
        public var description: String { "unparseable date '\(value)' in field '\(field)'" }
    }

    public func date(from string: String, field: String) throws -> Date {
        if let cached = cache[string] { return cached }
        guard let parsed = formatter.date(from: string) else {
            throw MalformedDateError(field: field, value: string)
        }
        cache[string] = parsed
        return parsed
    }
}
