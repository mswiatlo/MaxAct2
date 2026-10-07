import Foundation
import Testing

@testable import MaxActCore

/// Small, hand-built workouts whose TCX can be read and checked by eye. The golden files are the
/// contract with Strava; the structural tests say *why* each part of them is the way it is.
private enum TCXSample {
    static let start = Date(timeIntervalSince1970: 1_760_000_000)   // 2025-10-09T08:53:20Z

    /// A short ride: 6 fixes, a 10-minute café stop after the third, one teleport, and heart rate
    /// every 5 s. Small enough for its golden file to be read in full.
    static func ride() -> (Workout, WorkoutSeries) {
        func fix(_ second: TimeInterval, _ step: Double, speed: Double? = 5, accuracy: Double = 8,
                 latitude: Double? = nil) -> RoutePoint {
            RoutePoint(
                coordinate: Coordinate(latitude: latitude ?? 49.25, longitude: -123.1 + step * 0.0001),
                timestamp: start.addingTimeInterval(second),
                altitudeMeters: 50 + step,
                speedMetersPerSecond: speed,
                horizontalAccuracyMeters: accuracy
            )
        }
        let route = [
            fix(0, 0), fix(1, 1), fix(2, 2),
            // The measured artifact: no speed, poor accuracy, 1.8 km away. Must not be exported.
            fix(2.5, 2, speed: nil, accuracy: 45, latitude: 49.2664),
            // 10 minutes later: a pause, so a new <Track>.
            fix(602, 3), fix(603, 4), fix(604, 5),
        ]
        let heartRate = stride(from: 0.0, through: 605, by: 5).map {
            HeartRateSample(date: start.addingTimeInterval($0), minimum: 140, average: 140 + $0 / 100,
                            maximum: 140)
        }
        let workout = Workout(
            id: "RIDE-1", kind: .cycling, start: start, end: start.addingTimeInterval(605),
            duration: 5, distanceMeters: 40, activeEnergyKilocalories: 12.4,
            averageHeartRate: 143.2, maximumHeartRate: 146.0, hasRoute: true
        )
        return (workout, WorkoutSeries(workoutID: workout.id, route: route, heartRate: heartRate))
    }

    /// An indoor session: heart rate and nothing else.
    static func indoor() -> (Workout, WorkoutSeries) {
        let heartRate = stride(from: 0.0, through: 20, by: 5).map {
            HeartRateSample(date: start.addingTimeInterval($0), minimum: 120, average: 120 + $0,
                            maximum: 120)
        }
        let workout = Workout(
            id: "INDOOR-1", kind: .indoorCycling, start: start, end: start.addingTimeInterval(20),
            duration: 20, distanceMeters: nil, activeEnergyKilocalories: nil,
            averageHeartRate: 130, maximumHeartRate: 140, isIndoor: true
        )
        return (workout, WorkoutSeries(workoutID: workout.id, heartRate: heartRate))
    }
}

@Suite struct TCXWriterTests {
    // MARK: - Golden files

    /// Set `MAXACT_RECORD_GOLDEN=1` to rewrite the goldens — then read the diff before committing.
    private func assertGolden(_ name: String, _ actual: String) throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Fixtures/tcx/\(name).tcx")
        if ProcessInfo.processInfo.environment["MAXACT_RECORD_GOLDEN"] == "1" {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try actual.write(to: url, atomically: true, encoding: .utf8)
            Issue.record("Recorded golden \(name).tcx — re-run without MAXACT_RECORD_GOLDEN")
            return
        }
        let expected = try String(contentsOf: url, encoding: .utf8)
        #expect(actual == expected, "TCX for \(name) differs from its golden file")
    }

    @Test("a ride matches its golden file")
    func rideGolden() throws {
        let (workout, series) = TCXSample.ride()
        try assertGolden("ride", TCXWriter.document(for: workout, series: series))
    }

    @Test("an indoor session matches its golden file")
    func indoorGolden() throws {
        let (workout, series) = TCXSample.indoor()
        try assertGolden("indoor", TCXWriter.document(for: workout, series: series))
    }

    // MARK: - Why the file looks the way it does

    @Test("the output is well-formed XML")
    func wellFormed() {
        for (workout, series) in [TCXSample.ride(), TCXSample.indoor()] {
            let data = Data(TCXWriter.document(for: workout, series: series).utf8)
            #expect(XMLParser(data: data).parse(), "\(workout.id) is not well-formed")
        }
    }

    @Test("a pause starts a new track, so Strava doesn't count the stop as moving")
    func pauseSplitsTracks() {
        let (workout, series) = TCXSample.ride()
        let tracks = TCXWriter.tracks(for: workout, series: series)
        #expect(tracks.count == 2)
        #expect(tracks.map(\.count) == [3, 3])
    }

    @Test("the receiver's teleport is not exported")
    func teleportDropped() {
        let (workout, series) = TCXSample.ride()
        let document = TCXWriter.document(for: workout, series: series)
        #expect(!document.contains("49.2664"))
    }

    @Test("cumulative distance ends on the workout's own total")
    func distanceReconciles() throws {
        let (workout, series) = TCXSample.ride()
        let last = try #require(TCXWriter.tracks(for: workout, series: series).last?.last?.distance)
        #expect(abs(last - 40) < 0.01)
    }

    @Test("heart rate is attached only within five seconds of a reading")
    func heartRateTolerance() {
        let samples = [HeartRateSample(date: TCXSample.start, minimum: 150, average: 150, maximum: 150)]
        #expect(TCXWriter.nearestHeartRate(to: TCXSample.start.addingTimeInterval(4), in: samples) == 150)
        #expect(TCXWriter.nearestHeartRate(to: TCXSample.start.addingTimeInterval(6), in: samples) == nil)
        #expect(TCXWriter.nearestHeartRate(to: TCXSample.start, in: []) == nil)
    }

    @Test("timestamps are unique after rounding to whole seconds")
    func noDuplicateTimes() {
        // Two fixes in the same second would make Strava reject the file.
        let route = [0.0, 0.4, 0.9, 1.2].map {
            RoutePoint(coordinate: Coordinate(latitude: 49, longitude: -123 + $0 * 0.0001),
                       timestamp: TCXSample.start.addingTimeInterval($0),
                       speedMetersPerSecond: 3, horizontalAccuracyMeters: 5)
        }
        let workout = Workout(id: "W", kind: .running, start: TCXSample.start,
                              end: TCXSample.start.addingTimeInterval(2), duration: 2, distanceMeters: 5)
        let times = TCXWriter.tracks(for: workout, series: WorkoutSeries(workoutID: "W", route: route))
            .flatMap { $0 }.map(\.time)
        #expect(times == Array(Set(times)).sorted())
        #expect(times.count == 2)
    }

    @Test("an indoor session is still a valid file, with heart rate and no positions")
    func indoorHasNoPositions() {
        let (workout, series) = TCXSample.indoor()
        let document = TCXWriter.document(for: workout, series: series)
        #expect(!document.contains("<Position>"))
        #expect(document.contains("<HeartRateBpm><Value>140</Value></HeartRateBpm>"))
        #expect(document.contains("<Calories>0</Calories>"), "required by the schema")
    }

    @Test("numbers and times ignore the user's locale")
    func localeIndependent() {
        #expect(TCXWriter.number(1234.5, 1) == "1234.5")
        #expect(TCXWriter.timestamp(TCXSample.start) == "2025-10-09T08:53:20Z")
    }

    @Test("free text is escaped")
    func escaping() {
        #expect(TCXWriter.escape("Fish & <Chips>") == "Fish &amp; &lt;Chips&gt;")
    }
}

/// Validation against Garmin's published schema, vendored beside the goldens. `xmllint` ships with
/// macOS, and element *order* is the thing most easily got wrong by hand — the schema is a strict
/// sequence, and Strava rejects files that break it.
@Suite struct TCXSchemaTests {
    private static let fixtures = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .appending(path: "Fixtures/tcx")

    private func validate(_ document: String, _ name: String) throws {
        let file = FileManager.default.temporaryDirectory.appending(path: "\(name)-\(UUID()).tcx")
        try document.write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: file) }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xmllint")
        process.arguments = ["--noout", "--schema",
                             Self.fixtures.appending(path: "TrainingCenterDatabasev2.xsd").path, file.path]
        let errors = Pipe()
        process.standardError = errors
        try process.run()
        process.waitUntilExit()
        let message = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        #expect(process.terminationStatus == 0, "\(name) fails the TCX schema:\n\(message)")
    }

    @Test("the hand-built samples satisfy the schema")
    func samples() throws {
        for (workout, series) in [TCXSample.ride(), TCXSample.indoor()] {
            try validate(TCXWriter.document(for: workout, series: series), workout.id)
        }
    }

    @Test("every kind of seeded workout satisfies the schema")
    func seeded() throws {
        for item in SampleData.ingested(count: 12) {
            try validate(TCXWriter.document(for: item.workout, series: item.series), item.workout.id)
        }
    }

    /// Real recordings, when present: `MAXACT_REAL_SERIES=<dir of .json.lzfse>` runs every stored
    /// series through the writer and the schema, and leaves the TCX in the temp directory for
    /// inspection. Skipped otherwise — CI has no one's workouts.
    @Test("real stored series satisfy the schema",
          .enabled(if: ProcessInfo.processInfo.environment["MAXACT_REAL_SERIES"] != nil))
    func realSeries() async throws {
        let directory = URL(fileURLWithPath: ProcessInfo.processInfo.environment["MAXACT_REAL_SERIES"]!)
        let store = try SeriesStore(directory: directory)
        let ids = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { $0.hasSuffix(".json.lzfse") }
            .map { String($0.dropLast(".json.lzfse".count)) }
        #expect(!ids.isEmpty)
        for id in ids {
            let series = try await store.load(id)
            let start = (series.route.first?.timestamp ?? series.heartRate.first?.date) ?? .now
            let end = (series.route.last?.timestamp ?? series.heartRate.last?.date) ?? start
            let workout = Workout(id: id, kind: .cycling, start: start, end: end,
                                  duration: end.timeIntervalSince(start), hasRoute: !series.route.isEmpty)
            let document = TCXWriter.document(for: workout, series: series)
            try document.write(to: FileManager.default.temporaryDirectory.appending(path: "\(id).tcx"),
                               atomically: true, encoding: .utf8)
            try validate(document, id)
        }
    }
}
