import Foundation

/// Decodes the Health Auto Export **v2 workout JSON** envelope into canonical ``Workout`` values.
///
/// This one schema covers both transports we care about: the MCP `get_workouts` tool result and a
/// manual export file. (`.hae` files use a different, richer schema — see the skill reference.)
///
/// Two principles, both learned the hard way in Phase 1:
///
/// * **Lenient about shape.** Only `id`, `name`, `start`, `end` and `duration` are guaranteed.
///   Everything else is optional and unknown keys are ignored, so an HAE update can't brick sync.
/// * **Strict about units.** A quantity whose unit we don't recognise fails its workout rather
///   than being passed through. Misreading `kJ` as `kcal` produces a plausible number that is
///   wrong by 4.184×; a visible failure is strictly better.
///
/// One bad workout does not fail the batch: ``decode(_:)`` returns successes and failures side by
/// side, so a single unparseable entry in a weekly window can't stall a multi-year backfill.
public struct HAEWorkoutDecoder: Sendable {
    public init() {}

    public struct Failure: Error, Sendable {
        public let workoutID: String?
        public let underlying: any Error
    }

    public struct Result: Sendable {
        public let workouts: [IngestedWorkout]
        public let failures: [Failure]
        public var isCompleteSuccess: Bool { failures.isEmpty }
    }

    public enum EnvelopeError: Error, CustomStringConvertible {
        case notAnObject
        case missingRequiredField(String, workoutID: String?)

        public var description: String {
            switch self {
            case .notAnObject:
                "payload is not a JSON object"
            case .missingRequiredField(let field, let id):
                "missing required field '\(field)'\(id.map { " in workout \($0)" } ?? "")"
            }
        }
    }

    /// Decodes a full `{"data": {"workouts": [...]}}` payload.
    ///
    /// A payload carrying only `metrics`, or neither key, is a normal empty result — HAE pushes
    /// metrics-only bodies routinely and that is not an error.
    public func decode(_ data: Data) throws -> Result {
        let root = try JSONSerialization.jsonObject(with: data)
        guard let object = root as? [String: Any] else { throw EnvelopeError.notAnObject }
        let container = (object["data"] as? [String: Any]) ?? object
        let raw = (container["workouts"] as? [[String: Any]]) ?? []

        let parser = HAEDateParser()
        var workouts: [IngestedWorkout] = []
        var failures: [Failure] = []
        workouts.reserveCapacity(raw.count)

        for entry in raw {
            do {
                workouts.append(try decodeWorkout(entry, parser: parser))
            } catch {
                failures.append(Failure(workoutID: entry["id"] as? String, underlying: error))
            }
        }
        return Result(workouts: workouts, failures: failures)
    }

    // MARK: - One workout

    func decodeWorkout(_ entry: [String: Any], parser: HAEDateParser) throws -> IngestedWorkout {
        let id = entry["id"] as? String
        func required<T>(_ key: String, _ value: T?) throws -> T {
            guard let value else { throw EnvelopeError.missingRequiredField(key, workoutID: id) }
            return value
        }

        let workoutID = try required("id", id)
        let name = try required("name", entry["name"] as? String)
        let start = try parser.date(from: try required("start", entry["start"] as? String), field: "start")
        let end = try parser.date(from: try required("end", entry["end"] as? String), field: "end")
        let duration = try required("duration", entry["duration"] as? Double)

        let heartRateSummary = entry["heartRate"] as? [String: Any]
        let route = try decodeRoute(entry["route"] as? [[String: Any]] ?? [], parser: parser)

        let workout = Workout(
            id: workoutID,
            kind: ActivityKind(haeName: name),
            start: start,
            end: end,
            duration: duration,
            distanceMeters: try scalar(entry, "distance", .length),
            activeEnergyKilocalories: try scalar(entry, "activeEnergyBurned", .energy),
            totalEnergyKilocalories: try scalar(entry, "totalEnergy", .energy),
            elevationAscendedMeters: try scalar(entry, "elevationUp", .length),
            elevationDescendedMeters: try scalar(entry, "elevationDown", .length),
            // avgSpeed/maxSpeed arrive labelled "km"; Units handles that quirk for .speed fields.
            averageSpeedMetersPerSecond: try scalar(entry, "avgSpeed", .speed),
            maximumSpeedMetersPerSecond: try scalar(entry, "maxSpeed", .speed),
            averageHeartRate: try scalar(entry, "avgHeartRate", .rate)
                ?? scalar(heartRateSummary, "avg", .rate, qualifiedBy: "heartRate"),
            minimumHeartRate: try scalar(heartRateSummary, "min", .rate, qualifiedBy: "heartRate"),
            maximumHeartRate: try scalar(entry, "maxHeartRate", .rate)
                ?? scalar(heartRateSummary, "max", .rate, qualifiedBy: "heartRate"),
            isIndoor: indoorFlag(entry),
            sourceName: sourceName(entry["source"]),
            hasRoute: !route.isEmpty
        )

        let series = WorkoutSeries(
            workoutID: workoutID,
            route: route,
            heartRate: try heartRateSeries(entry["heartRateData"], field: "heartRateData", parser: parser),
            heartRateRecovery: try heartRateSeries(entry["heartRateRecovery"], field: "heartRateRecovery", parser: parser),
            activeEnergyKilocalories: try scalarSeries(entry["activeEnergy"], field: "activeEnergy", dimension: .energy, parser: parser),
            stepCount: try scalarSeries(entry["stepCount"], field: "stepCount", dimension: .count, parser: parser)
        )

        return IngestedWorkout(workout: workout, series: series)
    }

    // MARK: - Pieces

    /// A `{qty, units}` pair, converted. Absent → nil; present with an unknown unit → throws.
    private func scalar(
        _ container: [String: Any]?,
        _ key: String,
        _ dimension: Units.Dimension,
        qualifiedBy prefix: String? = nil
    ) throws -> Double? {
        guard let measurement = container?[key] as? [String: Any] else { return nil }
        guard let qty = measurement["qty"] as? Double else { return nil }
        let field = prefix.map { "\($0).\(key)" } ?? key
        guard let unit = measurement["units"] as? String else {
            // A bare qty with no unit is not safe to guess at.
            throw UnknownUnitError(field: field, unit: "<missing>", dimension: dimension)
        }
        return try Units.value(qty, in: unit, as: dimension, field: field)
    }

    /// `isIndoor` is a bool; `location` is the HealthKit session type as a string. Prefer the
    /// explicit flag, fall back to the string, and don't invent a value when neither is present.
    private func indoorFlag(_ entry: [String: Any]) -> Bool? {
        if let flag = entry["isIndoor"] as? Bool { return flag }
        guard let location = (entry["location"] as? String)?.lowercased() else { return nil }
        switch location {
        case "indoor": return true
        case "outdoor": return false
        default: return nil
        }
    }

    /// `source` is an object at workout level but a plain string inside series samples.
    private func sourceName(_ value: Any?) -> String? {
        if let name = value as? String { return name }
        return (value as? [String: Any])?["name"] as? String
    }

    private func decodeRoute(_ points: [[String: Any]], parser: HAEDateParser) throws -> [RoutePoint] {
        try points.compactMap { point in
            guard let latitude = point["latitude"] as? Double,
                  let longitude = point["longitude"] as? Double,
                  let timestamp = point["timestamp"] as? String
            else { return nil }  // a fix without a position or a time is unusable, not fatal
            return RoutePoint(
                coordinate: Coordinate(latitude: latitude, longitude: longitude),
                timestamp: try parser.date(from: timestamp, field: "route.timestamp"),
                altitudeMeters: point["altitude"] as? Double,
                speedMetersPerSecond: point["speed"] as? Double,
                courseDegrees: point["course"] as? Double,
                horizontalAccuracyMeters: point["horizontalAccuracy"] as? Double,
                verticalAccuracyMeters: point["verticalAccuracy"] as? Double,
                speedAccuracy: point["speedAccuracy"] as? Double,
                courseAccuracy: point["courseAccuracy"] as? Double
            )
        }
    }

    private func heartRateSeries(
        _ value: Any?, field: String, parser: HAEDateParser
    ) throws -> [HeartRateSample] {
        guard let samples = value as? [[String: Any]] else { return [] }
        return try samples.compactMap { sample in
            guard let date = sample["date"] as? String,
                  let avg = sample["Avg"] as? Double
            else { return nil }
            if let unit = sample["units"] as? String {
                _ = try Units.value(avg, in: unit, as: .rate, field: field)  // validate, bpm is canonical
            }
            return HeartRateSample(
                date: try parser.date(from: date, field: "\(field).date"),
                minimum: sample["Min"] as? Double ?? avg,
                average: avg,
                maximum: sample["Max"] as? Double ?? avg
            )
        }
    }

    private func scalarSeries(
        _ value: Any?, field: String, dimension: Units.Dimension, parser: HAEDateParser
    ) throws -> [SeriesSample] {
        guard let samples = value as? [[String: Any]] else { return [] }
        return try samples.compactMap { sample in
            guard let date = sample["date"] as? String, let qty = sample["qty"] as? Double else { return nil }
            guard let unit = sample["units"] as? String else {
                throw UnknownUnitError(field: field, unit: "<missing>", dimension: dimension)
            }
            return SeriesSample(
                date: try parser.date(from: date, field: "\(field).date"),
                value: try Units.value(qty, in: unit, as: dimension, field: field)
            )
        }
    }
}
