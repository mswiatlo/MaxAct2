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

    @Test("resume skips completed windows and keeps the rest in order")
    func frontierSkipsCompleted() throws {
        let start = try date("2026-01-01T00:00:00Z")
        let windows = SyncPlanner.windows(from: start, to: start.addingTimeInterval(28 * day))
        var frontier = SyncFrontier()
        frontier.markListed(windows[0])
        frontier.markListed(windows[2])

        let pending = frontier.pending(windows)
        #expect(pending == [windows[1], windows[3]])
        #expect(abs(frontier.progress(over: windows) - 0.5) < 1e-9)
    }

    @Test("a frontier round-trips through Codable, so it can be persisted in Phase 3")
    func frontierIsCodable() throws {
        let start = try date("2026-01-01T00:00:00Z")
        var frontier = SyncFrontier()
        frontier.markListed(SyncWindow(start: start, end: start.addingTimeInterval(7 * day)))
        frontier.markDetailFetched("WORKOUT-1")

        let restored = try JSONDecoder().decode(
            SyncFrontier.self, from: try JSONEncoder().encode(frontier)
        )
        #expect(restored == frontier)
        #expect(restored.needsDetail("WORKOUT-1") == false)
        #expect(restored.needsDetail("WORKOUT-2"))
    }

    @Test("re-listing a window is harmless, which is what makes resume safe")
    func markingIsIdempotent() throws {
        let start = try date("2026-01-01T00:00:00Z")
        let window = SyncWindow(start: start, end: start.addingTimeInterval(7 * day))
        var frontier = SyncFrontier()
        frontier.markListed(window)
        frontier.markListed(window)
        #expect(frontier.completedWindows.count == 1)
    }

    @Test("progress over an empty plan is complete, not a division by zero")
    func emptyPlanProgress() {
        #expect(SyncFrontier().progress(over: []) == 1)
    }
}
