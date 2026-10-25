import Foundation

/// Plans an "Everything" sync with no fixed start (issue 24): back from now until there's nothing
/// older, rather than a fixed seven years.
///
/// `get_workouts` can't say how far back a library goes — it has no limit or count, only date
/// windows, each costing ~2.4 s per workout found plus some per-request overhead. So the walk
/// finds the start by asking:
///
/// - **Weekly windows, newest first**, as for any sync: recent workouts land first, and an
///   interruption loses at most one week's work.
/// - **After a run of empty weeks**, a gap or the time before recording began, it **probes**
///   a wider window instead: a quarter, then a year, then everything back to ``floor``. An empty
///   probe skips its whole span in one request. A probe that finds workouts has them all, since
///   the list call returns every workout in its window, so the walk keeps them and goes on
///   weekly from the probe's start.
/// - **It ends** when it reaches ``floor``, which happens as soon as a probe stretching that far
///   comes back empty.
///
/// **Timeouts.** A probe that lands on a dense stretch is one long request, ~2.4 s per workout
/// against the client's 600 s limit. If one times out, ``recordTimeout(_:)`` keeps the cursor
/// where it was and limits later probes to narrower spans, ending with weekly windows, so a
/// dense region can't make it fail the same way twice.
///
/// Pure value logic: the app drives it with real requests (`AppModel.syncEverything`), and tests
/// drive it with a pretend library.
public struct BackfillWalker: Sendable, Equatable {
    /// Nothing older is asked for. Health launched in 2014, but other apps can write older
    /// workouts (an imported history), so the floor sits well before that; GPS fitness
    /// recordings older than 2000 are implausible.
    public static let floor = Date(timeIntervalSince1970: 946_684_800)   // 2000-01-01 00:00 UTC

    static let week: TimeInterval = 7 * 24 * 3600

    /// Consecutive empty weeks before probing. **To be measured** (issue 24): this trades
    /// requests in a sparse stretch against the risk of a probe landing on a dense one. Eight
    /// weeks is longer than any ordinary break, so probes only start in a real gap.
    public static let emptyWeeksBeforeProbing = 8

    /// Probe widths before the last one, which reaches all the way to ``floor``.
    static let probeSpans: [TimeInterval] = [91 * 24 * 3600, 365 * 24 * 3600]

    public struct Step: Sendable, Equatable {
        public let window: SyncWindow
        /// A wider window asked after a run of empty weeks, as opposed to an ordinary week.
        public let isProbe: Bool
    }

    /// Everything from here to the end has been listed.
    public private(set) var cursor: Date
    private let end: Date
    private var emptyWeeks = 0
    /// Which probe width comes next: an index into ``probeSpans``, or past it for the floor.
    private var probeLevel = 0
    /// The widest probe level still allowed. Lowered after a probe times out; -1 means weekly only.
    private var maximumProbeLevel = probeSpans.count

    public init(end: Date = .now) {
        self.end = end
        cursor = max(end, Self.floor)
    }

    public var isFinished: Bool { cursor <= Self.floor }

    /// The share of the span between ``floor`` and the end that's done, for a progress bar. It
    /// jumps forward when a probe skips a gap.
    public var progress: Double {
        let total = end.timeIntervalSince(Self.floor)
        guard total > 0 else { return 1 }
        return min(1, end.timeIntervalSince(cursor) / total)
    }

    /// The next window to ask for, or `nil` once finished.
    public func next() -> Step? {
        guard !isFinished else { return nil }
        guard emptyWeeks >= Self.emptyWeeksBeforeProbing, maximumProbeLevel >= 0 else {
            return Step(window: SyncWindow(start: max(Self.floor, cursor.addingTimeInterval(-Self.week)), end: cursor),
                        isProbe: false)
        }
        // Widening stops at the widest width still allowed, and keeps probing at that width:
        // after a floor-wide probe timed out, year-wide ones carry on back to the floor.
        let level = min(probeLevel, maximumProbeLevel)
        let start = level < Self.probeSpans.count
            ? max(Self.floor, cursor.addingTimeInterval(-Self.probeSpans[level]))
            : Self.floor
        return Step(window: SyncWindow(start: start, end: cursor), isProbe: true)
    }

    /// `step` was answered with `found` workouts, all of which the caller has kept.
    public mutating func record(_ step: Step, found: Int) {
        cursor = step.window.start
        if found > 0 {
            emptyWeeks = 0
            probeLevel = 0
        } else if step.isProbe {
            probeLevel += 1
        } else {
            emptyWeeks += 1
        }
    }

    /// `step` timed out. A probe is narrowed: the next tries the width below, and nothing as wide
    /// is tried again. A week that times out is a real failure, for the caller to report.
    /// - Returns: whether the walk can carry on.
    public mutating func recordTimeout(_ step: Step) -> Bool {
        guard step.isProbe else { return false }
        maximumProbeLevel = min(maximumProbeLevel, probeLevel) - 1
        probeLevel = max(0, maximumProbeLevel)
        return true
    }
}
