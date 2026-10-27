import Foundation
import Testing

@testable import MaxActCore

/// Issue 45: a payload from anyone pretending to be the phone mustn't name a path, crash the app,
/// or leave impossible numbers in the library.
@Suite struct InputValidationTests {
    /// One workout, with `extra` merged over a plausible baseline.
    static func payload(_ extra: [String: Any]) throws -> Data {
        var workout: [String: Any] = [
            "id": "A1B2C3D4-0000-4000-8000-000000000001", "name": "Outdoor Run",
            "start": "2025-10-08 12:00:00 -0700", "end": "2025-10-08 12:30:00 -0700", "duration": 1800.0,
        ]
        workout.merge(extra) { _, new in new }
        return try JSONSerialization.data(withJSONObject: ["data": ["workouts": [workout]]])
    }

    static func decode(_ extra: [String: Any]) throws -> HAEWorkoutDecoder.Result {
        try HAEWorkoutDecoder().decode(try payload(extra))
    }

    @Test("an id that could name a path, or isn't an id at all, fails its workout", arguments: [
        "../../escape", "a/b", "", "has space", "quote\"d", String(repeating: "a", count: 65), "é",
    ])
    func badIDs(_ id: String) throws {
        let result = try Self.decode(["id": id])
        #expect(result.workouts.isEmpty)
        #expect(result.failures.count == 1)
    }

    @Test("real ids pass", arguments: ["A1B2C3D4-0000-4000-8000-000000000001", "W1", "HK-1"])
    func goodIDs(_ id: String) throws {
        #expect(try Self.decode(["id": id]).workouts.count == 1)
    }

    @Test("an impossible duration fails its workout", arguments: [1e300, -5.0, 8.0 * 86_400])
    func badDurations(_ duration: Double) throws {
        #expect(try Self.decode(["duration": duration]).workouts.isEmpty)
    }

    @Test("an impossible optional figure is dropped, and the workout kept")
    func implausibleFiguresAreDropped() throws {
        let result = try Self.decode([
            "distance": ["qty": 1e300, "units": "km"],
            "avgHeartRate": ["qty": 5000.0, "units": "bpm"],
            "activeEnergyBurned": ["qty": 300.0, "units": "kcal"],
        ])
        let workout = try #require(result.workouts.first).workout
        #expect(workout.distanceMeters == nil)
        #expect(workout.averageHeartRate == nil)
        #expect(workout.activeEnergyKilocalories == 300, "a plausible figure is untouched")
    }

    @Test("impossible route points and readings are dropped")
    func implausibleRouteAndHeartRate() throws {
        let result = try Self.decode([
            "route": [
                ["latitude": 49.28, "longitude": -123.12, "timestamp": "2025-10-08 12:00:01 -0700", "altitude": 1e300],
                ["latitude": 999.0, "longitude": -123.12, "timestamp": "2025-10-08 12:00:02 -0700"],
                ["latitude": 49.28, "longitude": -123.12, "timestamp": "2025-10-08 12:00:03 -0700", "altitude": 30.0],
            ],
            "heartRateData": [
                ["date": "2025-10-08 12:00:01 -0700", "Avg": 1e300, "units": "bpm"],
                ["date": "2025-10-08 12:00:06 -0700", "Avg": 140.0, "Max": 9e99, "units": "bpm"],
            ],
        ])
        let series = try #require(result.workouts.first).series
        #expect(series.route.count == 2, "the point at latitude 999 is gone")
        #expect(series.route.first?.altitudeMeters == nil)
        #expect(series.route.last?.altitudeMeters == 30)
        #expect(series.heartRate.map(\.average) == [140])
        #expect(series.heartRate.first?.maximum == 140, "an impossible maximum falls back to the average")
    }

    @Test("a series file can't leave its folder, whatever the id")
    func seriesPathsStayInside() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "InputValidationTests-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try SeriesStore(directory: root)
        for id in ["../../escape", "a/b", "..", "ok-ID-1"] {
            let url = await store.fileURL(for: id).standardized
            #expect(url.deletingLastPathComponent().path == root.standardized.path, "\(id) → \(url.path)")
        }
        #expect(await store.fileName(for: "ok-ID-1") == "ok-ID-1.json.lzfse", "valid ids keep their names")
    }

    @Test("numbers convert without trapping")
    func saturating() {
        #expect(Int(saturating: 1e300) == .max)
        #expect(Int(saturating: -1e300) == .min)
        #expect(Int(saturating: .nan) == 0)
        #expect(Int(saturating: 42.0) == 42)
        // The formatters that used to trap on these.
        _ = WorkoutFormatting.duration(1e300)
        _ = WorkoutFormatting.energy(kilocalories: 1e300)
        _ = WorkoutFormatting.heartRate(1e300)
    }
}
