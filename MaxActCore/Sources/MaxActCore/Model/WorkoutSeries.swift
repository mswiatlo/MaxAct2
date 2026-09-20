import Foundation

/// One GPS fix. Canonical units: metres, metres per second, degrees.
public struct RoutePoint: Hashable, Sendable, Codable {
    public let coordinate: Coordinate
    public let timestamp: Date
    public let altitudeMeters: Double?
    public let speedMetersPerSecond: Double?
    public let courseDegrees: Double?
    public let horizontalAccuracyMeters: Double?
    public let verticalAccuracyMeters: Double?
    public let speedAccuracy: Double?
    public let courseAccuracy: Double?

    public init(
        coordinate: Coordinate,
        timestamp: Date,
        altitudeMeters: Double? = nil,
        speedMetersPerSecond: Double? = nil,
        courseDegrees: Double? = nil,
        horizontalAccuracyMeters: Double? = nil,
        verticalAccuracyMeters: Double? = nil,
        speedAccuracy: Double? = nil,
        courseAccuracy: Double? = nil
    ) {
        self.coordinate = coordinate
        self.timestamp = timestamp
        self.altitudeMeters = altitudeMeters
        self.speedMetersPerSecond = speedMetersPerSecond
        self.courseDegrees = courseDegrees
        self.horizontalAccuracyMeters = horizontalAccuracyMeters
        self.verticalAccuracyMeters = verticalAccuracyMeters
        self.speedAccuracy = speedAccuracy
        self.courseAccuracy = courseAccuracy
    }
}

/// A heart-rate bucket. HAE never sends beat-by-beat data — each sample is a min/avg/max over a
/// window whose width is set by `metadataAggregation` (5 s under `"seconds"`, 60 s under
/// `"minutes"`). Keep all three: charts want `avg`, TCX export wants `avg`, and min/max are the
/// only evidence of what the bucket flattened.
public struct HeartRateSample: Hashable, Sendable, Codable {
    public let date: Date
    public let minimum: Double
    public let average: Double
    public let maximum: Double

    public init(date: Date, minimum: Double, average: Double, maximum: Double) {
        self.date = date
        self.minimum = minimum
        self.average = average
        self.maximum = maximum
    }
}

/// A timestamped scalar from one of the workout's other series (active energy, step count,
/// cycling distance…), already converted to canonical units.
public struct SeriesSample: Hashable, Sendable, Codable {
    public let date: Date
    public let value: Double

    public init(date: Date, value: Double) {
        self.date = date
        self.value = value
    }
}

/// The per-sample data for one workout — the part that must not sit in the table's query path.
/// Stored as a compressed blob keyed by workout id (Phase 3).
public struct WorkoutSeries: Hashable, Sendable, Codable {
    public let workoutID: String

    /// GPS fixes, roughly 1 Hz but **not uniformly spaced** — gaps of many minutes appear where the
    /// workout was paused. Never interpolate across a long gap; it draws a line through the pause.
    public let route: [RoutePoint]
    public let heartRate: [HeartRateSample]
    public let heartRateRecovery: [HeartRateSample]
    public let activeEnergyKilocalories: [SeriesSample]
    public let stepCount: [SeriesSample]

    public init(
        workoutID: String,
        route: [RoutePoint] = [],
        heartRate: [HeartRateSample] = [],
        heartRateRecovery: [HeartRateSample] = [],
        activeEnergyKilocalories: [SeriesSample] = [],
        stepCount: [SeriesSample] = []
    ) {
        self.workoutID = workoutID
        self.route = route
        self.heartRate = heartRate
        self.heartRateRecovery = heartRateRecovery
        self.activeEnergyKilocalories = activeEnergyKilocalories
        self.stepCount = stepCount
    }

    public var isEmpty: Bool {
        route.isEmpty && heartRate.isEmpty && heartRateRecovery.isEmpty
            && activeEnergyKilocalories.isEmpty && stepCount.isEmpty
    }
}

/// What one decode of a workout yields: the row, plus whatever series came with it.
public struct IngestedWorkout: Hashable, Sendable {
    public let workout: Workout
    public let series: WorkoutSeries

    public init(workout: Workout, series: WorkoutSeries) {
        self.workout = workout
        self.series = series
    }
}
