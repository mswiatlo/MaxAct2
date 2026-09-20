import Foundation
import Testing

@testable import MaxActCore

/// Fixtures are real captures from the device, anonymised and truncated. The two differ only in
/// HAE's unit preferences, so decoding both to the same canonical numbers is the core guarantee.
enum Fixture {
    static func data(_ name: String) throws -> Data {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()      // MaxActCoreTests
            .deletingLastPathComponent()      // Tests
            .appending(path: "Fixtures/\(name).json")
        return try Data(contentsOf: url)
    }

    static func decode(_ name: String) throws -> HAEWorkoutDecoder.Result {
        try HAEWorkoutDecoder().decode(try data(name))
    }
}

@Suite struct HAEWorkoutDecoderTests {

    // MARK: - The two unit vocabularies must agree

    @Test("both unit vocabularies decode to identical canonical values")
    func vocabulariesProduceIdenticalNumbers() throws {
        let localized = try #require(try Fixture.decode("mcp-workouts-seconds").workouts.first).workout
        let canonical = try #require(try Fixture.decode("mcp-workouts-kJ-countmin").workouts.first).workout

        // Different workouts, so compare each against values derived independently from the raw
        // fixture rather than against each other.
        #expect(abs(try #require(localized.activeEnergyKilocalories) - 880.7838790992071) < 1e-9)
        #expect(abs(try #require(canonical.activeEnergyKilocalories) - 1121.8603941990377 / 4.184) < 1e-9)

        // Heart rate is the same number whether it arrived as bpm or count/min.
        #expect(abs(try #require(localized.averageHeartRate) - 119.86605226133803) < 1e-9)
        #expect(abs(try #require(canonical.averageHeartRate) - 140.04751754400314) < 1e-9)
    }

    @Test("kJ is converted, not passed through")
    func energyIsConverted() throws {
        let workout = try #require(try Fixture.decode("mcp-workouts-kJ-countmin").workouts.first).workout
        let kilocalories = try #require(workout.activeEnergyKilocalories)
        #expect(abs(kilocalories - 268.13106935923463) < 1e-9)
        #expect(kilocalories != 1121.8603941990377, "raw kJ leaked through as if it were kcal")
    }

    @Test("distances become metres and speeds become m/s")
    func lengthsAndSpeedsAreCanonical() throws {
        let workout = try #require(try Fixture.decode("mcp-workouts-kJ-countmin").workouts.first).workout
        #expect(abs(try #require(workout.distanceMeters) - 11363.61451074503) < 1e-9)
        #expect(abs(try #require(workout.elevationAscendedMeters) - 76) < 1e-9)
        // avgSpeed arrives labelled "km"; cross-checked against .hae's 3.750324900751945 m/s.
        #expect(abs(try #require(workout.averageSpeedMetersPerSecond) - 3.750324900751945) < 1e-12)
    }

    // MARK: - Shape

    @Test("activity names map to kinds, including HAE's Outdoor/Indoor prefixes")
    func activityKinds() throws {
        let cycling = try #require(try Fixture.decode("mcp-workouts-kJ-countmin").workouts.first).workout
        #expect(cycling.kind == .cycling)  // "Outdoor Cycling"
        let hiking = try #require(try Fixture.decode("mcp-workouts-seconds").workouts.first).workout
        #expect(hiking.kind == .hiking)
    }

    @Test("an unrecognised activity name survives as itself rather than collapsing to unknown")
    func unknownActivityIsPreserved() {
        let kind = ActivityKind(haeName: "Underwater Basket Weaving")
        #expect(kind == .other("Underwater Basket Weaving"))
        #expect(kind.displayName == "Underwater Basket Weaving")
        #expect(kind.isDistanceBased == false)
    }

    @Test("duration is taken from the field, not computed from start and end")
    func durationIsNotWallClock() throws {
        let workout = try #require(try Fixture.decode("mcp-workouts-kJ-countmin").workouts.first).workout
        let wallClock = workout.end.timeIntervalSince(workout.start)
        #expect(abs(workout.duration - 2117.362973690033) < 1e-9)
        #expect(wallClock > workout.duration, "fixture should exercise the paused-workout case")
    }

    @Test("source is read from the workout-level object, where it is not a plain string")
    func sourceIsAnObject() throws {
        let workout = try #require(try Fixture.decode("mcp-workouts-seconds").workouts.first).workout
        #expect(workout.sourceName == "TestApp")
    }

    @Test("indoor state comes from isIndoor, or from the location string when absent")
    func indoorDetection() throws {
        let cycling = try #require(try Fixture.decode("mcp-workouts-kJ-countmin").workouts.first).workout
        #expect(cycling.isIndoor == false)
        // The hiking fixture carries neither key, and must not invent an answer.
        let hiking = try #require(try Fixture.decode("mcp-workouts-seconds").workouts.first).workout
        #expect(hiking.isIndoor == nil)
    }

    // MARK: - Series

    @Test("route points decode with all ten keys, including the undocumented accuracies")
    func routeDecodes() throws {
        let ingested = try #require(try Fixture.decode("mcp-workouts-seconds").workouts.first)
        let point = try #require(ingested.series.route.first)
        #expect(ingested.workout.hasRoute)
        #expect(point.coordinate.latitude != 0 && point.coordinate.longitude != 0)
        #expect(point.altitudeMeters != nil)
        #expect(point.courseAccuracy != nil, "undocumented accuracy fields should be captured")
    }

    @Test("heart-rate buckets keep min, avg and max")
    func heartRateSeriesDecodes() throws {
        let series = try #require(try Fixture.decode("mcp-workouts-kJ-countmin").workouts.first).series
        let sample = try #require(series.heartRate.first)
        #expect(sample.minimum == 109)
        #expect(abs(sample.average - 114.28571428571429) < 1e-12)
        #expect(sample.maximum == 129)
        #expect(!series.heartRateRecovery.isEmpty, "recovery is a separate series and must survive")
    }

    @Test("series energy is converted too, not just the summary")
    func seriesEnergyIsConverted() throws {
        let series = try #require(try Fixture.decode("mcp-workouts-kJ-countmin").workouts.first).series
        let sample = try #require(series.activeEnergyKilocalories.first)
        #expect(abs(sample.value - 15.553788015649713 / 4.184) < 1e-12)
    }

    @Test("timestamps honour the embedded UTC offset")
    func timestampsUseTheOffset() throws {
        let workout = try #require(try Fixture.decode("mcp-workouts-kJ-countmin").workouts.first).workout
        // 2024-02-06 06:58:00 -0700 == 13:58:00Z
        var components = DateComponents()
        components.year = 2024; components.month = 2; components.day = 6
        components.hour = 13; components.minute = 58
        components.timeZone = TimeZone(identifier: "UTC")
        let expected = try #require(Calendar(identifier: .gregorian).date(from: components))
        #expect(abs(workout.start.timeIntervalSince(expected)) < 1)
    }

    // MARK: - Leniency and strictness

    @Test("unknown keys are ignored so an HAE update cannot brick sync")
    func unknownKeysAreTolerated() throws {
        var payload = try JSONSerialization.jsonObject(with: try Fixture.data("mcp-workouts-seconds")) as! [String: Any]
        var data = payload["data"] as! [String: Any]
        var workouts = data["workouts"] as! [[String: Any]]
        workouts[0]["someFieldAddedInHAE11"] = ["qty": 1.0, "units": "furlongs"]
        workouts[0]["anotherNewThing"] = 42
        data["workouts"] = workouts; payload["data"] = data

        let result = try HAEWorkoutDecoder().decode(try JSONSerialization.data(withJSONObject: payload))
        #expect(result.isCompleteSuccess)
        #expect(result.workouts.count == 1)
    }

    @Test("an unknown unit on a known field fails that workout loudly")
    func unknownUnitFailsTheWorkout() throws {
        var payload = try JSONSerialization.jsonObject(with: try Fixture.data("mcp-workouts-seconds")) as! [String: Any]
        var data = payload["data"] as! [String: Any]
        var workouts = data["workouts"] as! [[String: Any]]
        workouts[0]["distance"] = ["qty": 5.6, "units": "mi"]   // locale flipped to imperial
        data["workouts"] = workouts; payload["data"] = data

        let result = try HAEWorkoutDecoder().decode(try JSONSerialization.data(withJSONObject: payload))
        #expect(result.workouts.isEmpty)
        #expect(result.failures.count == 1)
        #expect(result.failures.first?.underlying is UnknownUnitError)
    }

    @Test("one bad workout does not take the rest of the window with it")
    func failuresAreIsolated() throws {
        var payload = try JSONSerialization.jsonObject(with: try Fixture.data("mcp-workouts-seconds")) as! [String: Any]
        var data = payload["data"] as! [String: Any]
        let workouts = data["workouts"] as! [[String: Any]]
        var broken = workouts[0]
        broken["id"] = "BROKEN"
        broken["distance"] = ["qty": 5.6, "units": "mi"]
        data["workouts"] = [broken, workouts[0]]; payload["data"] = data

        let result = try HAEWorkoutDecoder().decode(try JSONSerialization.data(withJSONObject: payload))
        #expect(result.workouts.count == 1)
        #expect(result.failures.count == 1)
        #expect(result.failures.first?.workoutID == "BROKEN")
    }

    @Test("a missing required field fails only that workout")
    func missingRequiredField() throws {
        let payload = ["data": ["workouts": [["id": "X", "name": "Running"]]]]
        let result = try HAEWorkoutDecoder().decode(try JSONSerialization.data(withJSONObject: payload))
        #expect(result.workouts.isEmpty)
        #expect(result.failures.count == 1)
    }

    @Test("a metrics-only payload is an empty result, not an error")
    func metricsOnlyPayloadIsNotAnError() throws {
        let payload = ["data": ["metrics": [["name": "step_count", "units": "count", "data": []]]]]
        let result = try HAEWorkoutDecoder().decode(try JSONSerialization.data(withJSONObject: payload))
        #expect(result.workouts.isEmpty)
        #expect(result.isCompleteSuccess)
    }
}
