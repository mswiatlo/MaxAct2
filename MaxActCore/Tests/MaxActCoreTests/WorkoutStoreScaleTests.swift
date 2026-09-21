import Foundation
import SwiftData
import Testing

@testable import MaxActCore

/// The denormalised-row / blob-on-disk split exists entirely to keep the table fast at seven
/// years of data. These assert that claim instead of taking it on faith.
///
/// **Thresholds sit an order of magnitude above the idle-machine measurements, deliberately.**
/// They catch a 10x regression; they are not benchmarks. Tight ones failed spuriously under load
/// — 2.8 s to list a corpus that takes 0.11 s idle, at load average 86 — and a performance
/// assertion you learn to ignore is worse than none. Read the printed figures for real numbers.
@Suite struct WorkoutStoreScaleTests {
    /// The measured corpus: ~2,867 workouts over seven years.
    static let corpusSize = 2_867

    @Test("a seven-year corpus inserts and lists without the table touching a blob")
    func fullCorpusListing() async throws {
        let store = WorkoutStore(modelContainer: try WorkoutStore.container(inMemory: true))
        let base = Date(timeIntervalSince1970: 1_500_000_000)

        let batch = (0..<Self.corpusSize).map { index in
            IngestedWorkout(
                workout: Workout(
                    id: "W\(index)",
                    kind: index % 3 == 0 ? .cycling : .running,
                    start: base.addingTimeInterval(Double(index) * 86_400 / 1.12),
                    end: base.addingTimeInterval(Double(index) * 86_400 / 1.12 + 3600),
                    duration: 3600,
                    distanceMeters: 10_000,
                    activeEnergyKilocalories: 250,
                    averageHeartRate: 140,
                    hasRoute: true
                ),
                series: WorkoutSeries(workoutID: "W\(index)")
            )
        }

        let insertStarted = Date()
        try await store.upsert(batch)
        let insertSeconds = Date().timeIntervalSince(insertStarted)

        let listStarted = Date()
        let items = try await store.allItems()
        let listSeconds = Date().timeIntervalSince(listStarted)

        print("insert \(Self.corpusSize): \(String(format: "%.2f", insertSeconds))s; "
              + "list all: \(String(format: "%.3f", listSeconds))s")

        #expect(items.count == Self.corpusSize)
        #expect(items.first?.workout.start ?? .distantPast > items.last?.workout.start ?? .distantFuture)
        // ~0.11 s idle; the ceiling is loose because a busy machine multiplies this severalfold
        // without anything being wrong with the code.
        #expect(listSeconds < 10, "listing the whole corpus should not become minutes")
    }

    @Test("a long route compresses enough that the projected corpus stays manageable")
    func routeCompression() async throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "MaxActScale-\(UUID().uuidString)")
        let seriesStore = try SeriesStore(directory: directory)

        // A 3.5-hour hike at 1 Hz: the largest real case measured in Phase 1.
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let series = WorkoutSeries(
            workoutID: "big",
            route: (0..<12_645).map { i in
                RoutePoint(
                    coordinate: Coordinate(
                        latitude: 49.25 + Double(i) * 0.00001,
                        longitude: -123.1 + Double(i) * 0.00001
                    ),
                    timestamp: base.addingTimeInterval(Double(i)),
                    altitudeMeters: 900 + Double(i % 50),
                    speedMetersPerSecond: 1.4,
                    courseDegrees: 296.3,
                    horizontalAccuracyMeters: 15.4
                )
            },
            heartRate: (0..<2_529).map { i in
                HeartRateSample(
                    date: base.addingTimeInterval(Double(i) * 5),
                    minimum: 110, average: 120, maximum: 130
                )
            }
        )

        try await seriesStore.save(series)
        let compressed = try await seriesStore.totalBytes()
        let uncompressed = try JSONEncoder().encode(series).count

        let ratio = Double(uncompressed) / Double(compressed)
        let projectedGB = Double(compressed) * Double(WorkoutStoreScaleTests.corpusSize) / 1_073_741_824
        print("largest route: \(uncompressed / 1024) KB JSON -> \(compressed / 1024) KB "
              + "(\(String(format: "%.1f", ratio))x); worst-case corpus \(String(format: "%.1f", projectedGB)) GB")

        #expect(ratio > 2, "LZFSE should at least halve this")
        // Every workout being a 3.5-hour hike is the pathological case; typical is ~10x smaller.
        #expect(projectedGB < 10)

        let loadStarted = Date()
        let loaded = try await seriesStore.load("big")
        let loadSeconds = Date().timeIntervalSince(loadStarted)
        print("load + decompress + decode: \(String(format: "%.3f", loadSeconds))s")

        #expect(loaded.route.count == series.route.count)
        #expect(loadSeconds < 1.0, "opening a workout must feel instant")
    }
}
