import Foundation

/// A half-open date range to sync.
public struct SyncWindow: Hashable, Sendable, Codable, CustomStringConvertible {
    public let start: Date
    public let end: Date

    public init(start: Date, end: Date) {
        self.start = start
        self.end = end
    }

    public var description: String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate]
        return "\(formatter.string(from: start))…\(formatter.string(from: end))"
    }
}

/// Where workouts come from.
///
/// Kept as a protocol because Phase 1 evaluated three viable sources and picked one on operational
/// grounds rather than data quality — the `.hae` reader in particular remains a plausible future
/// addition. It also lets the app be driven by a fixture source in tests and previews.
public protocol WorkoutSource: Sendable {
    /// Summaries for a window: no routes, minute-resolution series. The cheap pass.
    func listWorkouts(in window: SyncWindow) async throws -> HAEWorkoutDecoder.Result

    /// Everything for one workout: route plus second-resolution series. Roughly 2.5 MB and a few
    /// seconds each, so this is fetched on demand rather than for the whole corpus.
    func fetchDetail(for workout: Workout) async throws -> IngestedWorkout?
}

/// Splits a span into sync-sized chunks.
///
/// Weekly by default, from the Phase 1 measurement that cost scales with *workout count*, not
/// bytes or requests: per-request overhead is negligible against ~2.4 s per workout, so small
/// windows are nearly free. They buy two things — an interruption costs about 20 s of redone work
/// rather than minutes, and the phone builds each response in memory, so peak usage stays a few MB
/// instead of tens.
public enum SyncPlanner {
    public static func windows(
        from start: Date,
        to end: Date,
        chunk: TimeInterval = 7 * 24 * 3600
    ) -> [SyncWindow] {
        guard end > start, chunk > 0 else { return [] }
        var windows: [SyncWindow] = []
        var cursor = start
        while cursor < end {
            let next = min(cursor.addingTimeInterval(chunk), end)
            windows.append(SyncWindow(start: cursor, end: next))
            cursor = next
        }
        return windows
    }

    /// Newest first. A multi-year backfill should surface recent workouts immediately rather than
    /// starting seven years ago and showing nothing useful for an hour.
    public static func windowsNewestFirst(
        from start: Date,
        to end: Date,
        chunk: TimeInterval = 7 * 24 * 3600
    ) -> [SyncWindow] {
        windows(from: start, to: end, chunk: chunk).reversed()
    }
}

/// Which windows have been listed and which workouts have detail — the resumable part of sync.
///
/// Pure value logic here; Phase 3 persists it. Resume is possible at all because MCP requests are
/// independent date windows with no server-side cursor, and because upsert is keyed on the stable
/// workout UUID, so re-listing a partially-completed window is idempotent rather than duplicating.
public struct SyncFrontier: Sendable, Codable, Equatable {
    public private(set) var completedWindows: Set<SyncWindow>
    public private(set) var workoutsWithDetail: Set<String>

    public init(completedWindows: Set<SyncWindow> = [], workoutsWithDetail: Set<String> = []) {
        self.completedWindows = completedWindows
        self.workoutsWithDetail = workoutsWithDetail
    }

    public func pending(_ windows: [SyncWindow]) -> [SyncWindow] {
        windows.filter { !completedWindows.contains($0) }
    }

    public mutating func markListed(_ window: SyncWindow) {
        completedWindows.insert(window)
    }

    public mutating func markDetailFetched(_ workoutID: String) {
        workoutsWithDetail.insert(workoutID)
    }

    public func needsDetail(_ workoutID: String) -> Bool {
        !workoutsWithDetail.contains(workoutID)
    }

    /// Fraction of the given plan already listed, for progress reporting.
    public func progress(over windows: [SyncWindow]) -> Double {
        guard !windows.isEmpty else { return 1 }
        return Double(windows.count - pending(windows).count) / Double(windows.count)
    }
}
