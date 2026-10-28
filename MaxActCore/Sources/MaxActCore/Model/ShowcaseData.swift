import Foundation

/// A realistic library for the README's screenshots (issue 36): a few months of one person's
/// workouts on real Vancouver paths, dated up to yesterday.
///
/// Separate from ``SampleData`` on purpose. The tests lean on that one's exact shape — fixed dates,
/// a repaired first workout, two identical rides, altitudes of 5–35 m — while this one is built to
/// look like real use: speeds that follow the gradient, stops at lights, GPS jitter, heart rate that
/// lags effort and drifts. Deterministic all the same: every number comes from a seeded generator,
/// so the same day gives the same library.
public enum ShowcaseData {
    /// One workout, with what the store keeps beside it.
    public struct Entry: Sendable {
        public let ingested: IngestedWorkout
        public let placeLabel: String?
        public let place: PlaceDescription?
        public let tags: [String]
        /// A made-up activity id when "on Strava"; `nil` when not uploaded.
        public let stravaActivityID: Int?
        /// Which of ``ShowcaseRoutes`` it follows, if any.
        let route: String?
    }

    /// Ten weeks, newest first, ending the day before `now`.
    public static func library(endingAt now: Date, calendar: Calendar = .current) -> [Entry] {
        let today = calendar.startOfDay(for: now)
        var entries: [Entry] = []
        var index = 0
        for daysBack in 1...70 {
            guard let day = calendar.date(byAdding: .day, value: -daysBack, to: today) else { continue }
            let weekday = calendar.component(.weekday, from: day)   // 1 = Sunday
            let week = daysBack / 7
            for plan in plans(weekday: weekday, week: week) {
                let start = day.addingTimeInterval(plan.timeOfDay + Double(index % 7) * 60)
                entries.append(entry(plan, index: index, start: start, daysBack: daysBack))
                index += 1
            }
        }
        return entries.sorted { $0.ingested.workout.start > $1.ingested.workout.start }
    }

    // MARK: - The week

    enum Session: Sendable {
        case commute, easyRun, intervals, longRun, longRide, walk, grind, indoorRide, strength
    }

    struct Plan {
        let session: Session
        let timeOfDay: TimeInterval
    }

    private static func plans(weekday: Int, week: Int) -> [Plan] {
        let morning = 7.0 * 3600 + 55 * 60, evening = 18.0 * 3600 + 20 * 60, weekend = 9.0 * 3600 + 15 * 60
        switch weekday {
        case 2: return [Plan(session: .commute, timeOfDay: morning), Plan(session: .strength, timeOfDay: evening)]
        case 3: return [Plan(session: .easyRun, timeOfDay: evening)]
        case 4: return [Plan(session: .commute, timeOfDay: morning)]
            + (week.isMultiple(of: 2) ? [Plan(session: .indoorRide, timeOfDay: evening)] : [])
        case 5: return [Plan(session: .intervals, timeOfDay: evening)]
        case 6: return [Plan(session: .commute, timeOfDay: morning)]
        case 7: return [Plan(session: week.isMultiple(of: 2) ? .longRide : .longRun, timeOfDay: weekend)]
        case 1: return [Plan(session: week % 3 == 1 ? .grind : .walk, timeOfDay: weekend + 3600)]
        default: return []
        }
    }

    // MARK: - One workout

    /// How a session moves: its route (and how it's ridden), pace, effort and recording app.
    private struct Profile {
        let kind: ActivityKind
        let route: String?
        let outAndBack: Bool
        let laps: Int
        let speed: Double              // m/s on the flat
        let effort: Double             // fraction of heart-rate reserve
        let source: String
        let stops: Int                 // traffic lights and the like
        let pauses: Bool               // auto-pause: duration is moving time
    }

    private static func profile(_ session: Session, week: Int) -> Profile {
        // A little fitter each week back to now: ~0.4% faster per week.
        let form = 1 - Double(week) * 0.004
        switch session {
        case .commute: return Profile(kind: .cycling, route: "adanac-commute", outAndBack: false, laps: 1, speed: 6.1 * form,
                                      effort: 0.5, source: "Apple Watch", stops: 3, pauses: true)
        case .easyRun: return Profile(kind: .running, route: "kits-jericho", outAndBack: true, laps: 1, speed: 3.05 * form,
                                      effort: 0.66, source: "Apple Watch", stops: 1, pauses: true)
        case .intervals: return Profile(kind: .running, route: "false-creek", outAndBack: false, laps: 2, speed: 3.3 * form,
                                        effort: 0.72, source: "WorkOutDoors", stops: 0, pauses: true)
        case .longRun: return Profile(kind: .running, route: "stanley-park-seawall", outAndBack: false, laps: 1, speed: 2.95 * form,
                                      effort: 0.62, source: "Apple Watch", stops: 1, pauses: true)
        case .longRide: return Profile(kind: .cycling, route: "lions-gate-dundarave", outAndBack: true, laps: 1, speed: 6.6 * form,
                                       effort: 0.62, source: "Apple Watch", stops: 2, pauses: true)
        case .walk: return Profile(kind: .walking, route: "english-bay-walk", outAndBack: true, laps: 1, speed: 1.35,
                                   effort: 0.32, source: "Apple Watch", stops: 0, pauses: false)
        case .grind: return Profile(kind: .hiking, route: "grouse-grind", outAndBack: false, laps: 1, speed: 1.15 * form,
                                    effort: 0.7, source: "Apple Watch", stops: 0, pauses: false)
        case .indoorRide: return Profile(kind: .indoorCycling, route: nil, outAndBack: false, laps: 1, speed: 8.3 * form,
                                         effort: 0.68, source: "Apple Watch", stops: 0, pauses: false)
        case .strength: return Profile(kind: .strengthTraining, route: nil, outAndBack: false, laps: 1, speed: 0,
                                       effort: 0.45, source: "Apple Watch", stops: 0, pauses: false)
        }
    }

    static let restingHeartRate = 54.0, maximumHeartRate = 188.0

    private static func entry(_ plan: Plan, index: Int, start: Date, daysBack: Int) -> Entry {
        var random = SeededRandom(seed: UInt64(index) &* 0x9E37_79B9 &+ 17)
        let session = plan.session, profile = profile(session, week: daysBack / 7)
        let id = "SHOW-\(index)"
        let built = profile.route != nil
            ? outdoor(session, profile, id: id, start: start, random: &random)
            : indoor(session, profile, id: id, start: start, random: &random)

        // The oldest few outdoor workouts are list-only, as if their detail weren't downloaded yet.
        let listOnly = daysBack > 63 && profile.route != nil
        let ingested = listOnly
            ? IngestedWorkout(workout: built.workout.withRoute(false), series: WorkoutSeries(workoutID: id))
            : built

        let vancouver = PlaceDescription(city: "Vancouver", subdivision: "BC", country: "Canada", countryCode: "CA")
        let northVan = PlaceDescription(city: "North Vancouver", subdivision: "BC", country: "Canada", countryCode: "CA")
        let place: PlaceDescription? = profile.route == nil ? nil : (session == .grind ? northVan : vancouver)
        let tags: [String] = switch session {
        case .commute: ["Commute"]
        case .walk where index.isMultiple(of: 2): ["With Kid"]
        case .intervals: ["Intervals"]
        default: []
        }
        return Entry(
            ingested: ingested,
            placeLabel: place.map { "\($0.city ?? ""), \($0.subdivision ?? "")" },
            place: place,
            tags: tags,
            // The last few days not uploaded yet; everything older is on Strava.
            stravaActivityID: daysBack <= 3 ? nil : 16_000_000_000 + index * 7_919,
            route: profile.route
        )
    }

    // MARK: - Outdoor: a route, ridden

    private static func outdoor(_ session: Session, _ profile: Profile, id: String, start: Date,
                                random: inout SeededRandom) -> IngestedWorkout {
        var path = ShowcaseRoutes.points(profile.route ?? "", shoreline: profile.route != "grouse-grind")
        if profile.outAndBack { path += path.reversed().dropFirst() }
        if profile.laps > 1 { path = (0..<profile.laps).flatMap { lap in lap == 0 ? path : Array(path.dropFirst()) } }
        let track = Track(path)

        // Where the stops are, as distances along the path.
        let stopAt = (0..<profile.stops).map { _ in random.next(in: 0.15...0.85) * track.length }.sorted()
        var stopsLeft = stopAt[...]

        let step = 2.0                                   // seconds of simulation per tick
        let recordEvery = profile.kind == .cycling ? 2 : 3   // ticks between route points
        var distance = 0.0, time = 0.0, moving = 0.0, tick = 0
        var heartRate = restingHeartRate + 22, drift = 0.0
        var paceWander = 0.0, jitterX = 0.0, jitterY = 0.0
        var route: [RoutePoint] = [], heartRates: [HeartRateSample] = []
        var hrWindow: [Double] = []
        var maxSpeed = 0.0

        while distance < track.length {
            let here = track.at(distance)
            let grade = track.grade(at: distance)
            // Interval session: 6 × (2 min hard, 90 s easy) after a 10-minute warm-up.
            let intervalBoost: Double = {
                guard session == .intervals, moving > 600 else { return 0 }
                let cycle = (moving - 600).truncatingRemainder(dividingBy: 210)
                return moving < 600 + 6 * 210 && cycle < 120 ? 0.22 : -0.08
            }()
            paceWander += random.gaussian() * 0.012 - paceWander * 0.02
            let gradeFactor = profile.kind == .hiking ? 1 / (1 + max(grade, 0) * 3.5) : max(0.45, 1 - grade * (profile.kind == .cycling ? 6 : 3))
            var speed = profile.speed * (1 + paceWander + intervalBoost) * gradeFactor
            // Warm up over the first two minutes.
            speed *= min(1, 0.7 + moving / 400)

            // A stop: stand still for 20–45 s.
            var stopped = false
            if let next = stopsLeft.first, distance >= next {
                stopsLeft = stopsLeft.dropFirst()
                let wait = random.next(in: 20...45)
                for _ in 0..<Int(wait / step) {
                    time += step
                    heartRate += (restingHeartRate + 35 - heartRate) * 0.05
                    hrWindow.append(heartRate)
                    tick += 1
                    if tick % 5 == 0 { flush(&hrWindow, into: &heartRates, at: start.addingTimeInterval(time)) }
                }
                stopped = true
            }
            if stopped { speed = 0.3 }

            distance += speed * step
            time += step
            moving += step
            tick += 1
            maxSpeed = max(maxSpeed, speed)

            // Heart rate follows effort with a ~30 s lag, drifting up on long efforts.
            let effort = profile.effort + intervalBoost * 1.3 + max(grade, -0.05) * (profile.kind == .hiking ? 0.25 : 2)
            if moving > 1_200 { drift = min(drift + 0.004 * step, 8) }
            let target = min(restingHeartRate + (maximumHeartRate - restingHeartRate) * min(effort, 0.95) + drift,
                             maximumHeartRate - 4)
            heartRate += (target - heartRate) * (step / 30) + random.gaussian() * 0.6
            hrWindow.append(heartRate)
            if tick % 5 == 0 { flush(&hrWindow, into: &heartRates, at: start.addingTimeInterval(time)) }

            // GPS: a smooth few-metre wander off the path.
            jitterX += random.gaussian() * 0.8 - jitterX * 0.15
            jitterY += random.gaussian() * 0.8 - jitterY * 0.15
            if tick % recordEvery == 0 {
                route.append(RoutePoint(
                    coordinate: here.coordinate.offset(east: jitterX, north: jitterY),
                    timestamp: start.addingTimeInterval(time),
                    altitudeMeters: here.elevation + random.gaussian() * 0.15,
                    speedMetersPerSecond: max(0, speed + random.gaussian() * 0.15),
                    courseDegrees: track.course(at: distance),
                    horizontalAccuracyMeters: 3 + abs(random.gaussian()) * 2,
                    verticalAccuracyMeters: 4 + abs(random.gaussian()) * 2
                ))
            }
        }
        flush(&hrWindow, into: &heartRates, at: start.addingTimeInterval(time))

        let duration = profile.pauses ? moving : time
        let (ascent, descent) = climb(route.compactMap(\.altitudeMeters))
        let averageHeartRate = heartRates.map(\.average).reduce(0, +) / Double(max(heartRates.count, 1))
        let energy = kilocalories(heartRate: averageHeartRate, seconds: duration)
        let workout = Workout(
            id: id, kind: profile.kind, start: start, end: start.addingTimeInterval(time), duration: duration.rounded(),
            distanceMeters: track.length.rounded(),
            activeEnergyKilocalories: energy.rounded(),
            totalEnergyKilocalories: (energy + duration / 60 * 1.3).rounded(),
            elevationAscendedMeters: ascent.rounded(), elevationDescendedMeters: descent.rounded(),
            averageSpeedMetersPerSecond: track.length / duration, maximumSpeedMetersPerSecond: maxSpeed,
            averageHeartRate: averageHeartRate.rounded(),
            minimumHeartRate: heartRates.map(\.minimum).min()?.rounded(),
            maximumHeartRate: heartRates.map(\.maximum).max()?.rounded(),
            isIndoor: false, sourceName: profile.source, hasRoute: true
        )
        return IngestedWorkout(workout: workout, series: WorkoutSeries(workoutID: id, route: route, heartRate: heartRates))
    }

    // MARK: - Indoor: heart rate only

    private static func indoor(_ session: Session, _ profile: Profile, id: String, start: Date,
                               random: inout SeededRandom) -> IngestedWorkout {
        let minutes = session == .strength ? random.next(in: 38...52) : random.next(in: 40...55)
        let duration = (minutes * 60).rounded()
        var heartRate = restingHeartRate + 20, samples: [HeartRateSample] = [], window: [Double] = []
        var time = 0.0, tick = 0
        while time < duration {
            // Strength: sets of ~45 s with a minute's rest; the ride steadier, with a few surges.
            let phase = session == .strength
                ? ((time.truncatingRemainder(dividingBy: 105)) < 45 ? 0.62 : 0.38)
                : profile.effort + (time.truncatingRemainder(dividingBy: 600) < 90 ? 0.12 : 0)
            let warm = min(1, 0.6 + time / 600)
            let target = restingHeartRate + (maximumHeartRate - restingHeartRate) * phase * warm
            heartRate += (target - heartRate) * (2 / 25) + random.gaussian() * 0.7
            window.append(heartRate)
            time += 2; tick += 1
            if tick % 5 == 0 { flush(&window, into: &samples, at: start.addingTimeInterval(time)) }
        }
        flush(&window, into: &samples, at: start.addingTimeInterval(time))
        let average = samples.map(\.average).reduce(0, +) / Double(max(samples.count, 1))
        let energy = kilocalories(heartRate: average, seconds: duration)
        let workout = Workout(
            id: id, kind: profile.kind, start: start, end: start.addingTimeInterval(duration), duration: duration,
            distanceMeters: session == .indoorRide ? (profile.speed * duration).rounded() : nil,
            activeEnergyKilocalories: energy.rounded(),
            totalEnergyKilocalories: (energy + duration / 60 * 1.3).rounded(),
            averageSpeedMetersPerSecond: session == .indoorRide ? profile.speed : nil,
            averageHeartRate: average.rounded(),
            minimumHeartRate: samples.map(\.minimum).min()?.rounded(),
            maximumHeartRate: samples.map(\.maximum).max()?.rounded(),
            isIndoor: true, sourceName: profile.source, hasRoute: false
        )
        return IngestedWorkout(workout: workout, series: WorkoutSeries(workoutID: id, heartRate: samples))
    }

    // MARK: - Helpers

    /// Five-reading heart-rate buckets, as HAE sends them at "seconds" aggregation.
    private static func flush(_ window: inout [Double], into samples: inout [HeartRateSample], at date: Date) {
        guard !window.isEmpty else { return }
        let rounded = window.map { $0.rounded() }
        samples.append(HeartRateSample(date: date, minimum: rounded.min()!, average: (rounded.reduce(0, +) / Double(rounded.count)).rounded(),
                                       maximum: rounded.max()!))
        window.removeAll(keepingCapacity: true)
    }

    /// Total climb and descent, ignoring wobbles under 4 m, as a watch's barometer filter does.
    private static func climb(_ altitudes: [Double]) -> (Double, Double) {
        guard var anchor = altitudes.first else { return (0, 0) }
        var up = 0.0, down = 0.0
        for altitude in altitudes where abs(altitude - anchor) >= 4 {
            if altitude > anchor { up += altitude - anchor } else { down += anchor - altitude }
            anchor = altitude
        }
        return (up, down)
    }

    /// Keytel et al. (2005), for a 40-year-old 75 kg man.
    private static func kilocalories(heartRate: Double, seconds: Double) -> Double {
        max(0, (-55.0969 + 0.6309 * heartRate + 0.1988 * 75 + 0.2017 * 40) / 4.184 * seconds / 60)
    }
}

/// A polyline measured along its length.
private struct Track {
    let points: [(coordinate: Coordinate, elevation: Double)]
    let cumulative: [Double]
    var length: Double { cumulative.last ?? 0 }

    init(_ points: [(coordinate: Coordinate, elevation: Double)]) {
        self.points = points
        var total = 0.0, cumulative = [0.0]
        for (a, b) in zip(points, points.dropFirst()) {
            total += a.coordinate.metres(to: b.coordinate)
            cumulative.append(total)
        }
        self.cumulative = cumulative
    }

    private func segment(at distance: Double) -> (Int, Double) {
        var low = 0, high = cumulative.count - 1
        while high - low > 1 {
            let middle = (low + high) / 2
            if cumulative[middle] <= distance { low = middle } else { high = middle }
        }
        let span = cumulative[high] - cumulative[low]
        return (low, span > 0 ? min(max((distance - cumulative[low]) / span, 0), 1) : 0)
    }

    func at(_ distance: Double) -> (coordinate: Coordinate, elevation: Double) {
        let (i, t) = segment(at: min(distance, length))
        let a = points[i], b = points[min(i + 1, points.count - 1)]
        return (Coordinate(latitude: a.coordinate.latitude + (b.coordinate.latitude - a.coordinate.latitude) * t,
                           longitude: a.coordinate.longitude + (b.coordinate.longitude - a.coordinate.longitude) * t),
                a.elevation + (b.elevation - a.elevation) * t)
    }

    /// Rise over run across the next 40 m, which smooths the elevation model's steps.
    func grade(at distance: Double) -> Double {
        let ahead = min(distance + 40, length)
        guard ahead > distance else { return 0 }
        return (at(ahead).elevation - at(distance).elevation) / (ahead - distance)
    }

    func course(at distance: Double) -> Double {
        let a = at(distance).coordinate, b = at(min(distance + 10, length)).coordinate
        let degrees = atan2((b.longitude - a.longitude) * cos(a.latitude * .pi / 180), b.latitude - a.latitude) * 180 / .pi
        return (degrees + 360).truncatingRemainder(dividingBy: 360)
    }
}

/// SplitMix64: small, fast, and the same everywhere.
struct SeededRandom {
    private var state: UInt64
    init(seed: UInt64) { state = seed }

    mutating func nextUInt64() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    mutating func next(in range: ClosedRange<Double>) -> Double {
        range.lowerBound + Double(nextUInt64() >> 11) / Double(1 << 53) * (range.upperBound - range.lowerBound)
    }

    /// Standard normal, by Box–Muller.
    mutating func gaussian() -> Double {
        let u = max(next(in: 0...1), 1e-12), v = next(in: 0...1)
        return sqrt(-2 * log(u)) * cos(2 * .pi * v)
    }
}

private extension Coordinate {
    func metres(to other: Coordinate) -> Double {
        let lat = (latitude + other.latitude) / 2 * .pi / 180
        return hypot((other.latitude - latitude) * 111_320, (other.longitude - longitude) * 111_320 * cos(lat))
    }

    func offset(east: Double, north: Double) -> Coordinate {
        Coordinate(latitude: latitude + north / 111_320,
                   longitude: longitude + east / (111_320 * cos(latitude * .pi / 180)))
    }
}

private extension Workout {
    func withRoute(_ hasRoute: Bool) -> Workout {
        Workout(id: id, kind: kind, start: start, end: end, duration: duration, distanceMeters: distanceMeters,
                activeEnergyKilocalories: activeEnergyKilocalories, totalEnergyKilocalories: totalEnergyKilocalories,
                elevationAscendedMeters: elevationAscendedMeters, elevationDescendedMeters: elevationDescendedMeters,
                averageSpeedMetersPerSecond: averageSpeedMetersPerSecond, maximumSpeedMetersPerSecond: maximumSpeedMetersPerSecond,
                averageHeartRate: averageHeartRate, minimumHeartRate: minimumHeartRate, maximumHeartRate: maximumHeartRate,
                isIndoor: isIndoor, sourceName: sourceName, hasRoute: hasRoute)
    }
}
