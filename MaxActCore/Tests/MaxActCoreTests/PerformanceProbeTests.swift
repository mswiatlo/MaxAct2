import Foundation
import Testing

@testable import MaxActCore

/// Issue 41: measures, on a **copy** of the real library, the work the audit suspected of being
/// slow, so only what shows is fixed. Prints timings; asserts nothing.
///
///     MAXACT_PERF_LIBRARY=<dir holding default.store* and Series/> swift test --filter PerformanceProbe
///
/// Debug build, as the app runs from Xcode. Never point it at the live library: it opens the store.
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["MAXACT_PERF_LIBRARY"] != nil))
struct PerformanceProbeTests {
    static var root: URL { URL(fileURLWithPath: ProcessInfo.processInfo.environment["MAXACT_PERF_LIBRARY"]!) }

    /// Milliseconds `body` takes.
    static func ms(_ body: () -> Void) -> Double {
        let start = ContinuousClock.now
        body()
        let elapsed = ContinuousClock.now - start
        return Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15
    }

    static func summary(_ name: String, _ samples: [Double]) {
        let sorted = samples.sorted()
        guard !sorted.isEmpty else { return print("PERF \(name): no samples") }
        func pct(_ p: Double) -> Double { sorted[min(sorted.count - 1, Int(Double(sorted.count - 1) * p))] }
        print(String(format: "PERF %@: n %d  median %.1f ms  p95 %.1f ms  max %.1f ms  total %.0f ms",
                     name, sorted.count, pct(0.5), pct(0.95), sorted.last!, sorted.reduce(0, +)))
    }

    func library() async throws -> (items: [WorkoutListItem], series: SeriesStore) {
        let store = WorkoutStore(modelContainer: try WorkoutStore.container(at: Self.root.appending(path: "default.store")))
        return (try await store.allItems(), try SeriesStore(directory: Self.root.appending(path: "Series")))
    }

    /// What `WorkoutDetailView.load()` derives, step by step, for every workout with detail.
    @Test func openingAWorkout() async throws {
        let (items, seriesStore) = try await library()
        var load: [Double] = [], clean: [Double] = [], all: [Double] = [], points: [Int] = []
        for item in items where item.hasDetail {
            var series: WorkoutSeries?
            load.append(Self.ms { series = try? seriesStore.loadSync(item.id) })
            guard let series else { continue }
            points.append(series.route.count)
            clean.append(Self.ms { _ = series.cleanedRoute })
            let workout = item.workout
            all.append(Self.ms {
                let route = series.cleanedRoute
                _ = RouteSimplifier.simplify(route.map(\.coordinate), fittingPixels: 900)
                let hr = WorkoutCharts.heartRate(series), elevation = WorkoutCharts.elevation(series)
                let speed = WorkoutCharts.speed(series), pace = WorkoutCharts.pace(series, for: workout.kind)
                _ = workout.movingSpeedMetersPerSecond(using: series)
                _ = ElevationEstimate.ascent(route: route)
                _ = WorkoutSplits.splits(for: workout, series: series)
                _ = HeartRateHistogram(series.heartRate)
                _ = WorkoutCharts.timeDomain(for: workout, charts: [hr, elevation, workout.kind.isPaceBased ? pace : speed])
            })
        }
        print("PERF route points: max \(points.max() ?? 0), median \(points.sorted()[points.count / 2])")
        Self.summary("detail: load + decode", load)
        Self.summary("detail: one cleanedRoute", clean)
        Self.summary("detail: everything load() derives (main actor today)", all)
    }

    /// `RouteThumbnailRenderer.prepare`, on the main actor today, per thumbnail.
    @Test func preparingThumbnails() async throws {
        let (items, seriesStore) = try await library()
        var solid: [Double] = [], gradient: [Double] = []
        for item in items where item.hasDetail {
            guard let series = try? seriesStore.loadSync(item.id), series.route.count > 1 else { continue }
            solid.append(Self.ms {
                _ = RouteSimplifier.simplify(series.cleanedRoute.map(\.coordinate), fittingPixels: 96)
            })
            gradient.append(Self.ms {
                let route = series.cleanedRoute
                _ = RouteGradient(.elevation, route: route, heartRate: series.heartRate, profile: nil)?
                    .simplified(fittingPixels: 96)
            })
        }
        Self.summary("thumbnail prepare, solid", solid)
        Self.summary("thumbnail prepare, elevation", gradient)
    }

    /// Everything `StatisticsView.body` and its sections compute, as one render does, over the
    /// whole library.
    @Test func renderingStatistics() async throws {
        let (items, seriesStore) = try await library()
        let workouts = items.map(\.workout)
        let calendar = WorkoutStatistics.trainingCalendar(), now = Date.now
        let profile = try #require(HeartRateProfile(resting: 55, maximum: 190, curve: .male))
        var parts: [(String, Double)] = []
        func time(_ name: String, _ body: () -> Void) { parts.append((name, Self.ms(body))) }

        time("sort visible items (by date)") { _ = items.sorted { $0.workout.start > $1.workout.start } }
        time("totals ×4") {
            for period in [StatisticsPeriod.week, .month, .year] {
                _ = WorkoutStatistics.current(period, of: workouts, now: now, calendar: calendar)
            }
            _ = WorkoutStatistics.overall(workouts)
        }
        time("history by week") { _ = WorkoutStatistics.byPeriod(.week, of: workouts, through: now, calendar: calendar) }
        time("year progression") { _ = WorkoutStatistics.yearProgression(workouts, metric: .distance, now: now, calendar: calendar) }
        time("training load") { _ = TrainingLoad.days(workouts, profile: profile, through: now, calendar: calendar) }
        time("consistency (daily + streaks)") {
            _ = WorkoutStatistics.daily(workouts, from: now.addingTimeInterval(-365 * 86_400), through: now, calendar: calendar)
            _ = WorkoutStatistics.streaks(workouts, now: now, calendar: calendar)
        }
        time("personal bests ×2 (both ViewThatFits branches)") {
            let byKind = Dictionary(grouping: workouts, by: \.kind)
            for _ in 0..<2 { for group in byKind.values { _ = WorkoutStatistics.personalBests(group) } }
        }

        var sketches: [RouteSketch] = []
        for item in items where item.hasDetail {
            if let series = try? seriesStore.loadSync(item.id), let sketch = RouteSketch(series: series) { sketches.append(sketch) }
        }
        time("heatmap regions (\(sketches.count) sketches)") { _ = RouteHeatmap.regions(sketches, placeNames: [:]) }
        time("heatmap tiles ×3") { for _ in 0..<3 { _ = RouteHeatmap.tiles(sketches) } }
        // What the app's region cache compares on every redraw instead (issue 41).
        let names = Dictionary(items.compactMap { item in item.placeLabel.map { (item.id, $0) } }, uniquingKeysWith: { a, _ in a })
        let ids = sketches.map(\.workoutID), idsAgain = sketches.map(\.workoutID)
        let namesAgain = Dictionary(items.compactMap { item in item.placeLabel.map { (item.id, $0) } }, uniquingKeysWith: { a, _ in a })
        time("region cache hit: compare \(ids.count) ids and \(names.count) place names") {
            _ = ids == idsAgain && names == namesAgain
        }

        for (name, value) in parts { print(String(format: "PERF statistics: %@: %.1f ms", name, value)) }
        print(String(format: "PERF statistics: one render, all of the above: %.0f ms", parts.map(\.1).reduce(0, +)))
    }
}

extension PerformanceProbeTests {
    /// Issue 44: what each keystroke costs while deleting "California" from the search field.
    /// `visibleItems` filters and sorts the library each time it's read — about seven times per
    /// redraw of the table, title, Statistics and selection summary.
    @Test func searchingAndDeleting() async throws {
        let (items, _) = try await library()
        let sort = [KeyPathComparator(\WorkoutListItem.workout.start, order: .reverse)]
        let word = "California"
        print("PERF search: \(items.count) workouts")
        for length in stride(from: word.count, through: 1, by: -1) {
            let needle = String(word.prefix(length))
            var matched: [WorkoutListItem] = []
            let filter = Self.ms { matched = items.filter { $0.matches(searchText: needle) } }
            let sorted = Self.ms { _ = matched.sorted(using: sort) }
            print(String(format: "PERF search '%@': %d match, filter %.1f ms, sort %.1f ms", needle, matched.count, filter, sorted))
        }
        let all = Self.ms { _ = items.sorted(using: sort) }
        print(String(format: "PERF search: sorting all, %.1f ms", all))
    }
}

extension SeriesStore {
    /// A synchronous read for timing, outside the actor's queue.
    nonisolated func loadSync(_ workoutID: String) throws -> WorkoutSeries {
        let data = try Data(contentsOf: directory.appending(path: "\(workoutID).json.lzfse"))
        let json = try (data as NSData).decompressed(using: .lzfse) as Data
        return try JSONDecoder().decode(WorkoutSeries.self, from: json)
    }
}
