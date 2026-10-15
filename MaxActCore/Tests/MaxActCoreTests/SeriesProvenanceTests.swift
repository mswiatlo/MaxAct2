import Foundation
import Testing

@testable import MaxActCore

/// Issue 22: a series remembers which parts were repaired, so they can be re-done once Health Auto
/// Export fixes its export.
@Suite struct SeriesProvenanceTests {
    private let t0 = Date(timeIntervalSince1970: 1_760_000_000)

    private func point(_ seconds: Double, accuracy: Double?) -> RoutePoint {
        RoutePoint(coordinate: Coordinate(latitude: 49, longitude: -123 + seconds * 1e-5),
                   timestamp: t0.addingTimeInterval(seconds), horizontalAccuracyMeters: accuracy)
    }

    @Test("repairs record what the export had, and survive saving")
    func roundTrip() throws {
        let exported = WorkoutSeries(workoutID: "RUN", route: (0...27).map { point(Double($0), accuracy: 5) },
                                     heartRate: [HeartRateSample(date: t0, minimum: 140, average: 140, maximum: 140)])
        #expect(exported.provenance.isEmpty)
        let dense = (0..<360).map { HeartRateSample(date: t0.addingTimeInterval(Double($0) * 5), minimum: 150, average: 150, maximum: 150) }
        let repaired = exported.replacingHeartRate(dense)
            .replacingRoute((0...2500).map { point(Double($0), accuracy: nil) }, fromStravaActivity: 42)

        #expect(repaired.provenance.heartRateFromMetrics?.exportedReadings == 1)
        #expect(repaired.provenance.routeFromStrava == .init(activityID: 42, exportedSeconds: 27, exportedPoints: 28))
        let decoded = try JSONDecoder().decode(WorkoutSeries.self, from: JSONEncoder().encode(repaired))
        #expect(decoded == repaired)
        #expect(decoded.provenance == repaired.provenance)
    }

    @Test("a series saved before provenance existed still decodes, with none")
    func legacy() throws {
        let json = #"{"workoutID":"OLD","route":[],"heartRate":[],"heartRateRecovery":[],"activeEnergyKilocalories":[],"stepCount":[]}"#
        let decoded = try JSONDecoder().decode(WorkoutSeries.self, from: Data(json.utf8))
        #expect(decoded.workoutID == "OLD" && decoded.provenance.isEmpty)
    }

    @Test("workouts sharing a source with an unrecorded Strava-filled route are marked for re-download")
    func redownload() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "SeriesProvenanceTests-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let seriesStore = try SeriesStore(directory: root)
        let store = WorkoutStore(modelContainer: try WorkoutStore.container(inMemory: true))
        func item(_ id: String, source: String, accuracy: Double?, provenance: SeriesProvenance = .init()) -> IngestedWorkout {
            IngestedWorkout(
                workout: Workout(id: id, kind: .running, start: t0, end: t0.addingTimeInterval(600), duration: 600, sourceName: source),
                series: WorkoutSeries(workoutID: id, route: (0..<600).map { point(Double($0), accuracy: accuracy) }, provenance: provenance))
        }
        try await store.upsert([
            item("WATCH-FILLED", source: "Watch", accuracy: nil),          // Strava-filled, no record
            item("WATCH-OTHER", source: "Watch", accuracy: 5),              // same app, export route
            item("APP", source: "WorkOutDoors", accuracy: 5),
            item("RECORDED", source: "Recorded", accuracy: nil,             // already recorded: leave it
                 provenance: .init(routeFromStrava: .init(activityID: 1, exportedSeconds: 20, exportedPoints: 21))),
        ], seriesStore: seriesStore)

        let marked = try await store.markRepairedSourcesForRedownload(seriesStore: seriesStore)
        #expect(Set(marked) == ["WATCH-FILLED", "WATCH-OTHER"])
    }
}
