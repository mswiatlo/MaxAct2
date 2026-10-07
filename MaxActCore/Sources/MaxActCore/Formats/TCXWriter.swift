import Foundation

/// Writes a workout as Garmin Training Center XML (TCX v2), the format MaxAct uploads to Strava.
///
/// TCX rather than GPX or FIT because it is the one format that carries GPS, heart rate,
/// distance and calories together *and* still means something without a route — an indoor ride is
/// a valid TCX with heart rate and no positions. One writer, one set of golden files.
///
/// Decisions worth knowing before changing this:
///
/// - **The cleaned track, not the raw one.** ``RouteQuality`` drops the receiver's kilometre-scale
///   teleports. Exporting them would hand Strava a route with spikes in it, and Strava computes
///   its own distance and segments from the positions — a 1.8 km phantom detour is not something
///   to publish. The stored series is untouched either way.
/// - **A pause starts a new `<Track>`.** That is how Garmin devices encode a stop, and how Strava
///   tells moving time from elapsed time. A single track would make Strava draw a straight line
///   across the 51-minute café stop and count it as riding.
/// - **Cumulative distance is scaled to the workout's own total,** the same way the splits are.
///   Summing raw steps overstates distance by 4.5–12.9% even after cleaning; scaling makes the
///   last trackpoint agree with the lap total and with what HealthKit reported.
/// - **Heart rate is attached by nearest sample within 5 s.** HAE sends one reading every ~5 s
///   against ~1 Hz GPS, so most trackpoints sit between two readings. Interpolating would invent
///   precision the data doesn't have; leaving the gaps empty is honest and Strava fills them.
/// - **Timestamps are whole seconds in UTC.** Points that collide after rounding are dropped
///   rather than written twice, because duplicate times make Strava reject the file.
/// - **One lap.** HAE's MCP payload carries no laps; inventing kilometre laps would make Strava
///   show our reconstructed splits as if the watch had recorded them.
public enum TCXWriter {
    /// Gap within which a heart-rate reading is attached to a trackpoint.
    static let heartRateTolerance: TimeInterval = 5

    public static func document(for workout: Workout, series: WorkoutSeries) -> String {
        var xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <TrainingCenterDatabase xmlns="http://www.garmin.com/xmlschemas/TrainingCenterDatabase/v2" \
        xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" \
        xsi:schemaLocation="http://www.garmin.com/xmlschemas/TrainingCenterDatabase/v2 \
        http://www.garmin.com/xmlschemas/TrainingCenterDatabasev2.xsd">
          <Activities>
            <Activity Sport="\(sport(for: workout.kind))">
              <Id>\(timestamp(workout.start))</Id>
              <Lap StartTime="\(timestamp(workout.start))">
                <TotalTimeSeconds>\(number(workout.duration, 0))</TotalTimeSeconds>
                <DistanceMeters>\(number(workout.distanceMeters ?? 0, 1))</DistanceMeters>

        """
        if let calories = workout.activeEnergyKilocalories {
            xml += "        <Calories>\(Int(calories.rounded()))</Calories>\n"
        } else {
            // Required by the schema, so zero rather than omitted when HAE had nothing.
            xml += "        <Calories>0</Calories>\n"
        }
        if let average = workout.averageHeartRate {
            xml += heartRateElement("AverageHeartRateBpm", average, indent: 8)
        }
        if let maximum = workout.maximumHeartRate {
            xml += heartRateElement("MaximumHeartRateBpm", maximum, indent: 8)
        }
        xml += "        <Intensity>Active</Intensity>\n"
        xml += "        <TriggerMethod>Manual</TriggerMethod>\n"

        for track in tracks(for: workout, series: series) where !track.isEmpty {
            xml += "        <Track>\n"
            for point in track { xml += trackpoint(point) }
            xml += "        </Track>\n"
        }

        xml += """
              </Lap>
              <Notes>\(escape("Exported by MaxAct from Apple Health (\(workout.kind.displayName))"))</Notes>
            </Activity>
          </Activities>
        </TrainingCenterDatabase>

        """
        return xml
    }

    // MARK: - Trackpoints

    struct Point: Equatable {
        let time: Int          // whole seconds since 1970
        var latitude: Double?
        var longitude: Double?
        var altitude: Double?
        var distance: Double?
        var heartRate: Int?
    }

    /// The trackpoints, already split into tracks at pauses.
    static func tracks(for workout: Workout, series: WorkoutSeries) -> [[Point]] {
        let route = series.cleanedRoute
        return route.count >= 2
            ? routeTracks(route, workout: workout, heartRate: series.heartRate)
            : heartRateOnlyTracks(series.heartRate)
    }

    private static func routeTracks(
        _ route: [RoutePoint], workout: Workout, heartRate: [HeartRateSample]
    ) -> [[Point]] {
        let steps = zip(route, route.dropFirst()).map {
            WorkoutSplits.distance(from: $0.coordinate, to: $1.coordinate)
        }
        let measured = steps.reduce(0, +)
        let scale = (workout.distanceMeters.map { measured > 0 ? $0 / measured : 1 }) ?? 1

        var tracks: [[Point]] = [[]]
        var cumulative = 0.0
        var lastTime: Int?
        var lastDate: Date?

        for (index, fix) in route.enumerated() {
            if index > 0 { cumulative += steps[index - 1] * scale }
            let time = Int(fix.timestamp.timeIntervalSince1970.rounded(.down))
            if time == lastTime { continue }
            if let lastDate, fix.timestamp.timeIntervalSince(lastDate) > RouteQuality.pauseGapSeconds {
                tracks.append([])
            }
            tracks[tracks.count - 1].append(Point(
                time: time,
                latitude: fix.coordinate.latitude,
                longitude: fix.coordinate.longitude,
                altitude: fix.altitudeMeters,
                distance: cumulative,
                heartRate: nearestHeartRate(to: fix.timestamp, in: heartRate)
            ))
            lastTime = time
            lastDate = fix.timestamp
        }
        return tracks
    }

    /// No route — an indoor session. Heart rate alone still makes a valid, useful file.
    private static func heartRateOnlyTracks(_ samples: [HeartRateSample]) -> [[Point]] {
        var tracks: [[Point]] = [[]]
        var lastTime: Int?
        var lastDate: Date?
        for sample in samples.sorted(by: { $0.date < $1.date }) {
            let time = Int(sample.date.timeIntervalSince1970.rounded(.down))
            if time == lastTime { continue }
            if let lastDate, sample.date.timeIntervalSince(lastDate) > RouteQuality.pauseGapSeconds {
                tracks.append([])
            }
            tracks[tracks.count - 1].append(Point(
                time: time, heartRate: Int(sample.average.rounded())
            ))
            lastTime = time
            lastDate = sample.date
        }
        return tracks
    }

    /// Binary search: the samples are time-ordered and a long ride has thousands of fixes.
    static func nearestHeartRate(to date: Date, in samples: [HeartRateSample]) -> Int? {
        guard !samples.isEmpty else { return nil }
        var low = 0, high = samples.count - 1
        while low < high {
            let mid = (low + high) / 2
            if samples[mid].date < date { low = mid + 1 } else { high = mid }
        }
        let candidates = [low - 1, low].filter { samples.indices.contains($0) }
        guard let best = candidates.min(by: {
            abs(samples[$0].date.timeIntervalSince(date)) < abs(samples[$1].date.timeIntervalSince(date))
        }) else { return nil }
        guard abs(samples[best].date.timeIntervalSince(date)) <= heartRateTolerance else { return nil }
        return Int(samples[best].average.rounded())
    }

    private static func trackpoint(_ point: Point) -> String {
        var xml = "          <Trackpoint>\n"
        xml += "            <Time>\(timestamp(Date(timeIntervalSince1970: TimeInterval(point.time))))</Time>\n"
        if let latitude = point.latitude, let longitude = point.longitude {
            xml += "            <Position>\n"
            xml += "              <LatitudeDegrees>\(number(latitude, 7))</LatitudeDegrees>\n"
            xml += "              <LongitudeDegrees>\(number(longitude, 7))</LongitudeDegrees>\n"
            xml += "            </Position>\n"
        }
        if let altitude = point.altitude {
            xml += "            <AltitudeMeters>\(number(altitude, 1))</AltitudeMeters>\n"
        }
        if let distance = point.distance {
            xml += "            <DistanceMeters>\(number(distance, 1))</DistanceMeters>\n"
        }
        if let heartRate = point.heartRate {
            xml += heartRateElement("HeartRateBpm", Double(heartRate), indent: 12)
        }
        xml += "          </Trackpoint>\n"
        return xml
    }

    // MARK: - Formatting

    private static func heartRateElement(_ name: String, _ bpm: Double, indent: Int) -> String {
        let pad = String(repeating: " ", count: indent)
        return "\(pad)<\(name)><Value>\(Int(bpm.rounded()))</Value></\(name)>\n"
    }

    /// TCX only knows three sports, and Strava infers the activity type from this attribute — the
    /// upload API has no type parameter. So walks and hikes are **"Other"**, not "Running": mapping
    /// them to the nearest foot sport would publish a walk as a run, and the follow-up
    /// `PUT sport_type` that corrects it might not happen (rate limit, network). "Other" is wrong
    /// in a harmless direction; "Running" is wrong in one that pollutes running statistics.
    static func sport(for kind: ActivityKind) -> String {
        switch kind {
        case .running: "Running"
        case .cycling, .indoorCycling: "Biking"
        default: "Other"
        }
    }

    /// `2026-09-17T23:06:00Z`. Built by hand rather than with a formatter so the output can never
    /// pick up a locale or a time zone.
    static func timestamp(_ date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        return String(
            format: "%04d-%02d-%02dT%02d:%02d:%02dZ",
            parts.year!, parts.month!, parts.day!, parts.hour!, parts.minute!, parts.second!
        )
    }

    /// Fixed decimals with a `.` separator whatever the user's locale.
    static func number(_ value: Double, _ decimals: Int) -> String {
        String(format: "%.\(decimals)f", locale: Locale(identifier: "en_US_POSIX"), value)
    }

    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}
