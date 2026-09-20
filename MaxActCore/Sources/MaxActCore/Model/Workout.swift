import Foundation

/// A geographic position. Kept free of CoreLocation so the package stays testable and portable.
public struct Coordinate: Hashable, Sendable, Codable {
    public let latitude: Double
    public let longitude: Double

    public init(latitude: Double, longitude: Double) {
        self.latitude = latitude
        self.longitude = longitude
    }
}

/// One workout, in MaxAct's canonical units: **metres, seconds, kilocalories, metres per second,
/// bpm**. Unit strings from Health Auto Export are normalised away at decode time and never stored
/// — they track the user's HAE preferences and are not stable.
///
/// This is the list-view payload. The heavy per-sample data lives in ``WorkoutSeries``.
public struct Workout: Identifiable, Hashable, Sendable {
    /// HealthKit's workout UUID, stable across transports and re-syncs. The dedupe key.
    public let id: String
    public let kind: ActivityKind
    public let start: Date
    public let end: Date

    /// Elapsed workout time in seconds. **Not** `end - start`: a paused workout's wall-clock span
    /// can be far longer (94.7 min against a 35 min duration, measured). Slice series on
    /// `start`/`end`, never on `start + duration`.
    public let duration: TimeInterval

    public let distanceMeters: Double?
    public let activeEnergyKilocalories: Double?
    public let totalEnergyKilocalories: Double?
    public let elevationAscendedMeters: Double?
    public let elevationDescendedMeters: Double?
    public let averageSpeedMetersPerSecond: Double?
    public let maximumSpeedMetersPerSecond: Double?
    public let averageHeartRate: Double?
    public let minimumHeartRate: Double?
    public let maximumHeartRate: Double?
    public let isIndoor: Bool?

    /// The recording app, e.g. `"WorkOutDoors"` — HAE reports this as an object at workout level.
    public let sourceName: String?

    /// True when the payload carried route points. Lets the list show a thumbnail placeholder
    /// without loading the series blob.
    public let hasRoute: Bool

    public init(
        id: String,
        kind: ActivityKind,
        start: Date,
        end: Date,
        duration: TimeInterval,
        distanceMeters: Double? = nil,
        activeEnergyKilocalories: Double? = nil,
        totalEnergyKilocalories: Double? = nil,
        elevationAscendedMeters: Double? = nil,
        elevationDescendedMeters: Double? = nil,
        averageSpeedMetersPerSecond: Double? = nil,
        maximumSpeedMetersPerSecond: Double? = nil,
        averageHeartRate: Double? = nil,
        minimumHeartRate: Double? = nil,
        maximumHeartRate: Double? = nil,
        isIndoor: Bool? = nil,
        sourceName: String? = nil,
        hasRoute: Bool = false
    ) {
        self.id = id
        self.kind = kind
        self.start = start
        self.end = end
        self.duration = duration
        self.distanceMeters = distanceMeters
        self.activeEnergyKilocalories = activeEnergyKilocalories
        self.totalEnergyKilocalories = totalEnergyKilocalories
        self.elevationAscendedMeters = elevationAscendedMeters
        self.elevationDescendedMeters = elevationDescendedMeters
        self.averageSpeedMetersPerSecond = averageSpeedMetersPerSecond
        self.maximumSpeedMetersPerSecond = maximumSpeedMetersPerSecond
        self.averageHeartRate = averageHeartRate
        self.minimumHeartRate = minimumHeartRate
        self.maximumHeartRate = maximumHeartRate
        self.isIndoor = isIndoor
        self.sourceName = sourceName
        self.hasRoute = hasRoute
    }
}
