import Foundation
import Testing

@testable import MaxActCore

@Suite struct SyncPlannerTests {
    private let day: TimeInterval = 24 * 3600

    private func date(_ iso: String) throws -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate, .withTime, .withColonSeparatorInTime, .withTimeZone]
        return try #require(formatter.date(from: iso))
    }

    @Test("a span splits into whole weeks with a short final window")
    func weeklyChunking() throws {
        let start = try date("2026-01-01T00:00:00Z")
        let windows = SyncPlanner.windows(from: start, to: start.addingTimeInterval(10 * day))
        #expect(windows.count == 2)
        #expect(windows[0].start == start)
        #expect(windows[1].end == start.addingTimeInterval(10 * day))
        // Contiguous and non-overlapping: no workout can fall between two windows.
        #expect(windows[0].end == windows[1].start)
    }

    @Test("windows tile the whole span exactly")
    func windowsCoverEverything() throws {
        let start = try date("2019-01-01T00:00:00Z")
        let end = try date("2026-01-01T00:00:00Z")
        let windows = SyncPlanner.windows(from: start, to: end)
        #expect(windows.first?.start == start)
        #expect(windows.last?.end == end)
        for (a, b) in zip(windows, windows.dropFirst()) { #expect(a.end == b.start) }
        let total = windows.reduce(0.0) { $0 + $1.end.timeIntervalSince($1.start) }
        #expect(abs(total - end.timeIntervalSince(start)) < 1)
    }

    @Test("seven years is a few hundred chunks, so an interruption costs seconds not minutes")
    func sevenYearPlanIsFineGrained() throws {
        let end = try date("2026-01-01T00:00:00Z")
        let windows = SyncPlanner.windows(from: end.addingTimeInterval(-7 * 365 * day), to: end)
        #expect(windows.count == 365)
        // ~2,867 workouts over the span at ~2.4 s each, spread across these windows.
        let workoutsPerWindow = 2867.0 / Double(windows.count)
        #expect(workoutsPerWindow * 2.4 < 30, "a lost chunk should cost well under a minute to redo")
    }

    @Test("backfill runs newest first so recent workouts appear immediately")
    func newestFirstOrdering() throws {
        let start = try date("2026-01-01T00:00:00Z")
        let end = start.addingTimeInterval(21 * day)
        let windows = SyncPlanner.windowsNewestFirst(from: start, to: end)
        #expect(windows.first?.end == end)
        #expect(windows.last?.start == start)
    }

    @Test("degenerate spans produce no work rather than an infinite loop")
    func degenerateSpans() throws {
        let now = try date("2026-01-01T00:00:00Z")
        #expect(SyncPlanner.windows(from: now, to: now).isEmpty)
        #expect(SyncPlanner.windows(from: now, to: now.addingTimeInterval(-day)).isEmpty)
        #expect(SyncPlanner.windows(from: now, to: now.addingTimeInterval(day), chunk: 0).isEmpty)
    }

    // MARK: - Frontier
}
