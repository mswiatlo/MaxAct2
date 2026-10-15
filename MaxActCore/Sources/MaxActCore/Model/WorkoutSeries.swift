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
    /// Which parts didn't come from Health Auto Export's workout export (issue 22). Optional so
    /// series saved before it existed still decode; read ``provenance``.
    private let repairs: SeriesProvenance?

    public init(
        workoutID: String,
        route: [RoutePoint] = [],
        heartRate: [HeartRateSample] = [],
        heartRateRecovery: [HeartRateSample] = [],
        activeEnergyKilocalories: [SeriesSample] = [],
        stepCount: [SeriesSample] = [],
        provenance: SeriesProvenance = SeriesProvenance()
    ) {
        self.workoutID = workoutID
        self.route = route
        self.heartRate = heartRate
        self.heartRateRecovery = heartRateRecovery
        self.activeEnergyKilocalories = activeEnergyKilocalories
        self.stepCount = stepCount
        self.repairs = provenance.isEmpty ? nil : provenance
    }

    public var provenance: SeriesProvenance { repairs ?? SeriesProvenance() }

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

extension WorkoutSeries {
    /// Whether `samples` are too sparse to be a workout's heart rate: fewer than one reading a
    /// minute, over a workout of at least two minutes.
    ///
    /// Health Auto Export's workout export sends the Apple Workout app's heart rate this way. That
    /// app stores heart rate as series samples, chunks of ~10 minutes holding a reading every few
    /// seconds, and the export gives one averaged reading per chunk — measured: 3 readings for a
    /// 30-minute run that Strava and `get_health_metrics` both have at 1–5 s. WorkOutDoors stores
    /// each reading on its own, and its workouts come through at 5 s.
    public static func heartRateIsSparse(_ samples: [HeartRateSample], duration: TimeInterval) -> Bool {
        duration >= 120 && Double(samples.count) < duration / 60
    }

    /// The same series with its heart rate replaced from Health's samples, recording how many
    /// readings the export had.
    public func replacingHeartRate(_ heartRate: [HeartRateSample]) -> WorkoutSeries {
        var provenance = provenance
        provenance.heartRateFromMetrics = .init(exportedReadings: self.heartRate.count)
        return WorkoutSeries(workoutID: workoutID, route: route, heartRate: heartRate, heartRateRecovery: heartRateRecovery,
                             activeEnergyKilocalories: activeEnergyKilocalories, stepCount: stepCount, provenance: provenance)
    }
}

extension WorkoutSeries {
    /// Whether the route covers under half the workout's duration — what Health Auto Export sends
    /// for some interval-style Apple Workout-app recordings: one piece of a route stored in several
    /// (measured: 57 s of a 30-minute run, and 27 s of 48 minutes, where Strava had all of it).
    /// Every other route in the user's library covers at least 98%. `false` with no route at all.
    public func routeIsIncomplete(duration: TimeInterval) -> Bool {
        guard duration >= 120, let first = route.first, let last = route.last else { return false }
        return last.timestamp.timeIntervalSince(first.timestamp) < duration / 2
    }

    /// How long the route spans, start to finish.
    public var routeSpan: TimeInterval {
        guard let first = route.first, let last = route.last else { return 0 }
        return last.timestamp.timeIntervalSince(first.timestamp)
    }

    /// The same series with its route replaced by the Strava activity's, recording what the
    /// export had sent.
    public func replacingRoute(_ route: [RoutePoint], fromStravaActivity activityID: Int) -> WorkoutSeries {
        var provenance = provenance
        provenance.routeFromStrava = .init(activityID: activityID, exportedSeconds: routeSpan, exportedPoints: self.route.count)
        return WorkoutSeries(workoutID: workoutID, route: route, heartRate: heartRate, heartRateRecovery: heartRateRecovery,
                             activeEnergyKilocalories: activeEnergyKilocalories, stepCount: stepCount, provenance: provenance)
    }
}

/// Where a series' parts came from, when not from Health Auto Export's workout export — the
/// workarounds for issue 21's export bugs, recorded so the workouts can be found and re-downloaded
/// once Health Auto Export fixes them.
public struct SeriesProvenance: Hashable, Sendable, Codable {
    /// The route came from the linked Strava activity; the export had sent only part of it.
    public struct StravaRoute: Hashable, Sendable, Codable {
        public let activityID: Int
        public let exportedSeconds: TimeInterval
        public let exportedPoints: Int
    }

    /// The heart rate came from `get_health_metrics`; the export had averaged it into a few readings.
    public struct MetricsHeartRate: Hashable, Sendable, Codable {
        public let exportedReadings: Int
    }

    public var routeFromStrava: StravaRoute?
    public var heartRateFromMetrics: MetricsHeartRate?

    public init(routeFromStrava: StravaRoute? = nil, heartRateFromMetrics: MetricsHeartRate? = nil) {
        self.routeFromStrava = routeFromStrava
        self.heartRateFromMetrics = heartRateFromMetrics
    }

    public var isEmpty: Bool { routeFromStrava == nil && heartRateFromMetrics == nil }
}
