import Foundation
import Testing
@testable import MaxActCore

@Suite struct BackfillWalkerTests {
    static let day: TimeInterval = 86_400
    static let end = Date(timeIntervalSince1970: 1_761_350_400)   // 2025-10-25

    /// A pretend library: workouts at these dates, answering any window with the ones inside it,
    /// and timing out on more than `timeoutAbove`, as the phone would at ~2.4 s each against a
    /// 600 s limit.
    struct Library {
        let dates: [Date]
        var timeoutAbove = 250

        func answer(_ window: SyncWindow) -> Int? {
            let count = dates.count { $0 >= window.start && $0 < window.end }
            return count > timeoutAbove ? nil : count
        }
    }

    struct Run {
        var steps: [BackfillWalker.Step] = []
        /// The steps that were answered — the ones that move the walk on.
        var answered: [BackfillWalker.Step] = []
        var found = 0
        var timeouts = 0
        var failed = false
    }

    /// Drives a walker to the end against `library`, as `AppModel` does against the phone.
    static func walk(_ library: Library, end: Date = end) -> Run {
        var walker = BackfillWalker(end: end)
        var run = Run()
        while let step = walker.next() {
            run.steps.append(step)
            if let count = library.answer(step.window) {
                run.found += count
                run.answered.append(step)
                walker.record(step, found: count)
            } else {
                run.timeouts += 1
                guard walker.recordTimeout(step) else { run.failed = true; break }
            }
            #expect(run.steps.count < 5_000, "the walk should end")
            if run.steps.count >= 5_000 { break }
        }
        return run
    }

    /// One workout a day for `days` days back from `from`.
    static func daily(from: Date, days: Int, every: Int = 1) -> [Date] {
        stride(from: 0, to: days, by: every).map { from.addingTimeInterval(-Double($0) * day - 3600) }
    }

    /// Dense recent years, a two-year gap, then an old imported cluster from 2010.
    static let realistic: [Date] = {
        let recent = daily(from: end, days: 3 * 365)
        let oldEnd = end.addingTimeInterval(-5 * 365 * day)
        let older = daily(from: oldEnd, days: 2 * 365, every: 2)
        let imported = daily(from: Date(timeIntervalSince1970: 1_293_840_000), days: 200, every: 3)  // 2011 back
        return recent + older + imported
    }()

    @Test func findsEveryWorkoutInFarFewerRequestsThanWeeklyToTheFloor() {
        let run = Self.walk(Library(dates: Self.realistic))
        #expect(!run.failed)
        #expect(run.found == Self.realistic.count)
        let weeklyToFloor = Int(Self.end.timeIntervalSince(BackfillWalker.floor) / (7 * Self.day))
        #expect(run.steps.count < weeklyToFloor / 2, "\(run.steps.count) requests against \(weeklyToFloor) weekly")
    }

    /// No gaps and no overlaps: the answered windows tile the span from the floor to the end
    /// exactly, so nothing is missed and nothing listed twice. (A timed-out probe is retried
    /// narrower from the same place, so it isn't one of the tiles.)
    @Test func windowsTileTheWholeSpanExactly() {
        let run = Self.walk(Library(dates: Self.realistic))
        let windows = run.answered.map(\.window)
        #expect(windows.first?.end == Self.end)
        #expect(windows.last?.start == BackfillWalker.floor)
        for (newer, older) in zip(windows, windows.dropFirst()) {
            #expect(older.end == newer.start)
        }
    }

    @Test func recentWorkoutsComeFirstInWeeklyWindows() {
        let run = Self.walk(Library(dates: Self.realistic))
        let firstYear = run.steps.prefix(52)
        #expect(firstYear.allSatisfy { !$0.isProbe && $0.window.end.timeIntervalSince($0.window.start) <= 7 * Self.day })
    }

    /// A probe landing on a dense stretch times out; the walk narrows and still gets everything,
    /// without timing out again on the same width.
    @Test func aProbeThatTimesOutNarrowsAndStillFindsEverything() {
        // A gap long enough to probe, then a stretch too dense for one year's request.
        let recent = Self.daily(from: Self.end, days: 60)
        let denseEnd = Self.end.addingTimeInterval(-200 * Self.day)
        let dense = (0..<400).map { denseEnd.addingTimeInterval(-Double($0) * Self.day / 2) }  // 2 a day for 200 days
        // A lower limit than the phone's, so the first probe into the dense stretch must time out.
        let library = Library(dates: recent + dense, timeoutAbove: 20)
        let run = Self.walk(library)
        #expect(!run.failed)
        #expect(run.found == library.dates.count)
        #expect(run.timeouts >= 1)
        #expect(run.timeouts <= BackfillWalker.probeSpans.count + 1)
    }

    @Test func aWeekThatTimesOutIsAFailure() throws {
        var walker = BackfillWalker(end: Self.end)
        let step = try #require(walker.next())
        #expect(!step.isProbe)
        let carriesOn = walker.recordTimeout(step)
        #expect(!carriesOn)
    }

    /// An empty library: a few weeks, the probes, and done.
    @Test func anEmptyLibraryEndsQuickly() {
        let run = Self.walk(Library(dates: []))
        #expect(run.found == 0)
        #expect(run.steps.count == BackfillWalker.emptyWeeksBeforeProbing + BackfillWalker.probeSpans.count + 1)
    }

    @Test func progressRunsFromZeroToOne() {
        var walker = BackfillWalker(end: Self.end)
        #expect(walker.progress == 0)
        while let step = walker.next() { walker.record(step, found: 0) }
        #expect(walker.isFinished)
        #expect(walker.progress == 1)
    }
}
