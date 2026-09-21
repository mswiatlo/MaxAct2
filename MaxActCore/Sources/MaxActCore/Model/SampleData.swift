import Foundation

/// Synthetic workouts for UI tests and SwiftUI previews.
///
/// Exists because every user-visible bug so far — a crash while scrolling, an indoor icon on
/// outdoor rides, a thumbnail that never appeared, a render that never retried — was invisible to
/// the test suite for one reason: the tests ran against an empty database, so the table, the
/// thumbnail pipeline and the detail pane had nothing to go wrong with.
///
/// Two properties matter and are easy to get wrong:
///
/// * **Deterministic.** Everything derives from the index, with no randomness and no `Date.now`
///   beyond the caller-supplied end date, so a failing test reproduces.
/// * **Real coordinates.** Routes are laid over Vancouver. `MKMapSnapshotter` returns blank
///   ocean tiles for coordinates in the middle of nowhere, which would make any assertion about
///   a rendered thumbnail pass without meaning.
public enum SampleData {
    /// Vancouver: real streets, so snapshots come back with real tiles.
    public static let origin = Coordinate(latitude: 49.2827, longitude: -123.1207)

    /// A repeating cycle of activities, chosen to exercise the cases the UI treats differently:
    /// distance-based and not, indoor and outdoor.
    private static let kinds: [ActivityKind] = [
        .cycling, .running, .walking, .strengthTraining, .hiking, .indoorCycling,
    ]

    public static func kind(at index: Int) -> ActivityKind {
        kinds[index % kinds.count]
    }

    /// `count` workouts, one per day working backwards from `endingAt`, newest first.
    public static func workouts(
        count: Int,
        endingAt end: Date = Date(timeIntervalSince1970: 1_760_000_000)
    ) -> [Workout] {
        (0..<count).map { index in
            let kind = kind(at: index)
            let start = end.addingTimeInterval(-Double(index) * 86_400)
            // Vary the numbers so sorting by any column produces a visibly different order — a
            // table where every row is identical can't catch a broken sort.
            let minutes = Double(20 + (index * 7) % 70)
            let duration = minutes * 60
            let distance = kind.isDistanceBased ? Double(3_000 + (index * 1_300) % 22_000) : nil
            let indoor = kind == .indoorCycling || kind == .strengthTraining

            return Workout(
                id: "SEED-\(index)",
                kind: kind,
                start: start,
                end: start.addingTimeInterval(duration * 1.2),
                duration: duration,
                distanceMeters: distance,
                activeEnergyKilocalories: Double(80 + (index * 37) % 600),
                totalEnergyKilocalories: Double(160 + (index * 41) % 700),
                elevationAscendedMeters: indoor ? nil : Double((index * 17) % 300),
                elevationDescendedMeters: indoor ? nil : Double((index * 19) % 300),
                averageHeartRate: Double(95 + (index * 11) % 70),
                minimumHeartRate: Double(60 + index % 15),
                maximumHeartRate: Double(150 + (index * 13) % 40),
                isIndoor: indoor,
                sourceName: index.isMultiple(of: 3) ? "WorkOutDoors" : "Apple Watch",
                // Matches a list-pass sync: routes are not known until detail is fetched, so this
                // stays false even for workouts that will get a series. That asymmetry is exactly
                // what the indoor-icon bug got wrong.
                hasRoute: false
            )
        }
    }

    /// A plausible route and heart-rate series for one workout.
    ///
    /// The track is a loop around the origin, sized by the workout's distance, with enough points
    /// to exercise simplification but few enough to seed quickly.
    public static func series(for workout: Workout, points: Int = 300) -> WorkoutSeries {
        let radius = min(max((workout.distanceMeters ?? 5_000) / 250_000, 0.004), 0.05)
        let route = (0..<points).map { step -> RoutePoint in
            let t = Double(step) / Double(points) * 2 * .pi
            return RoutePoint(
                coordinate: Coordinate(
                    latitude: origin.latitude + sin(t) * radius,
                    // Longitude degrees are shorter this far north; 1.5 keeps the loop round.
                    longitude: origin.longitude + cos(t) * radius * 1.5
                ),
                timestamp: workout.start.addingTimeInterval(
                    Double(step) / Double(points) * workout.duration
                ),
                altitudeMeters: 20 + sin(t * 3) * 15,
                speedMetersPerSecond: 4 + sin(t * 5),
                courseDegrees: (t * 180 / .pi).truncatingRemainder(dividingBy: 360),
                horizontalAccuracyMeters: 5
            )
        }

        let heartRateSamples = max(Int(workout.duration / 5), 2)
        let heartRate = (0..<heartRateSamples).map { step -> HeartRateSample in
            let average = (workout.averageHeartRate ?? 120) + sin(Double(step) / 20) * 12
            return HeartRateSample(
                date: workout.start.addingTimeInterval(Double(step) * 5),
                minimum: average - 4,
                average: average,
                maximum: average + 4
            )
        }

        return WorkoutSeries(workoutID: workout.id, route: route, heartRate: heartRate)
    }

    /// Workouts ready to upsert, with a series attached to every `withSeriesEvery`-th **outdoor**
    /// one.
    ///
    /// The mix is the point: rows with a route, rows awaiting download, and indoor rows that will
    /// never have one. Those are the three placeholder states the thumbnail view distinguishes,
    /// and conflating two of them was a real bug.
    public static func ingested(
        count: Int,
        withSeriesEvery: Int = 3,
        endingAt end: Date = Date(timeIntervalSince1970: 1_760_000_000)
    ) -> [IngestedWorkout] {
        workouts(count: count, endingAt: end).enumerated().map { index, workout in
            let wantsSeries = index.isMultiple(of: withSeriesEvery) && workout.isIndoor != true
            guard wantsSeries else {
                return IngestedWorkout(workout: workout, series: WorkoutSeries(workoutID: workout.id))
            }
            // A workout arriving *with* a route reports it, as a real detail fetch would.
            var withRoute = workout
            withRoute = Workout(
                id: workout.id, kind: workout.kind, start: workout.start, end: workout.end,
                duration: workout.duration, distanceMeters: workout.distanceMeters,
                activeEnergyKilocalories: workout.activeEnergyKilocalories,
                totalEnergyKilocalories: workout.totalEnergyKilocalories,
                elevationAscendedMeters: workout.elevationAscendedMeters,
                elevationDescendedMeters: workout.elevationDescendedMeters,
                averageSpeedMetersPerSecond: workout.averageSpeedMetersPerSecond,
                maximumSpeedMetersPerSecond: workout.maximumSpeedMetersPerSecond,
                averageHeartRate: workout.averageHeartRate,
                minimumHeartRate: workout.minimumHeartRate,
                maximumHeartRate: workout.maximumHeartRate,
                isIndoor: workout.isIndoor, sourceName: workout.sourceName,
                hasRoute: true
            )
            return IngestedWorkout(workout: withRoute, series: series(for: withRoute))
        }
    }
}
