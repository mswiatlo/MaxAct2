import Foundation
import Testing

@testable import MaxActCore

/// Issue 17: importing one chosen month.
@Suite struct SyncMonthTests {
    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/Vancouver")!
        return c
    }
    private func at(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: y, month: m, day: d, hour: h))!
    }

    @Test("a past month runs from local midnight on the 1st to local midnight on the next 1st")
    func pastMonth() throws {
        let march = try #require(SyncPlanner.month(3, of: 2024, calendar: calendar, now: at(2026, 10, 14)))
        #expect(march.start == at(2024, 3, 1))
        #expect(march.end == at(2024, 4, 1))
        // March 2024 contains the spring DST change: one hour short of 31 days.
        #expect(march.duration == 31 * 86_400 - 3600)
    }

    @Test("the month in progress ends now; a month to come doesn't exist yet")
    func currentAndFuture() throws {
        let now = at(2026, 10, 14, 9)
        let october = try #require(SyncPlanner.month(10, of: 2026, calendar: calendar, now: now))
        #expect(october.start == at(2026, 10, 1))
        #expect(october.end == now)
        #expect(SyncPlanner.month(11, of: 2026, calendar: calendar, now: now) == nil)
    }

    @Test("a month splits into the usual weekly windows, newest first, covering it exactly")
    func windows() throws {
        let february = try #require(SyncPlanner.month(2, of: 2025, calendar: calendar, now: at(2026, 10, 14)))
        let windows = SyncPlanner.windowsNewestFirst(from: february.start, to: february.end)
        #expect(windows.count == 4)
        #expect(windows.last?.start == february.start)
        #expect(windows.first?.end == february.end)
    }
}
