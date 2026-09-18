import Foundation
import Testing

@testable import MaxActCore

/// Health Auto Export stamps every timestamp with an explicit UTC offset. Parsing must honour that
/// offset rather than assuming the Mac's current time zone, or workouts recorded while travelling
/// land on the wrong day.
@Suite struct HAEDateFormatTests {
    private var formatter: DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = MaxActCore.haeDateFormat
        return formatter
    }

    @Test func parsesTimestampWithNegativeOffset() throws {
        let date = try #require(formatter.date(from: "2024-02-06 07:00:00 -0800"))
        #expect(date.timeIntervalSince1970 == 1_707_231_600)
    }

    @Test func offsetIsHonouredRatherThanIgnored() throws {
        let pacific = try #require(formatter.date(from: "2024-02-06 07:00:00 -0800"))
        let utc = try #require(formatter.date(from: "2024-02-06 07:00:00 +0000"))
        #expect(pacific.timeIntervalSince(utc) == 8 * 3600)
    }
}
