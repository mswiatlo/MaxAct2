import Foundation
import MaxActCore
import Testing

@testable import MaxAct2

/// Issue 38: starts the geocoder can't name mustn't hide older workouts from it.
@Suite struct PlaceResolverTests {
    static let park = Coordinate(latitude: 49.30, longitude: -123.14)
    static let town = Coordinate(latitude: 49.10, longitude: -122.60)

    /// One workout a day, newest first: `newest` starting in the park, then `older` in the town.
    static func store(newest: Int, older: Int) async throws -> WorkoutStore {
        let store = WorkoutStore(modelContainer: try WorkoutStore.container(inMemory: true))
        let series = try SeriesStore(directory: FileManager.default.temporaryDirectory
            .appending(path: "PlaceResolverTests-\(UUID().uuidString)"))
        let now = Date(timeIntervalSince1970: 1_760_000_000)
        let workouts = (0..<(newest + older)).map { day in
            let start = now.addingTimeInterval(-Double(day) * 86_400)
            let at = day < newest ? park : town
            let route = (0..<3).map { i in
                RoutePoint(coordinate: Coordinate(latitude: at.latitude, longitude: at.longitude + Double(i) * 0.0001),
                           timestamp: start.addingTimeInterval(Double(i)), altitudeMeters: nil,
                           speedMetersPerSecond: 3, courseDegrees: nil, horizontalAccuracyMeters: 5)
            }
            let workout = Workout(id: "W\(day)", kind: .running, start: start, end: start.addingTimeInterval(600),
                                  duration: 600, hasRoute: true)
            return IngestedWorkout(workout: workout, series: WorkoutSeries(workoutID: workout.id, route: route))
        }
        try await store.upsert(workouts, seriesStore: series)
        return store
    }

    @Test func unnameableNewestStartsDontHideOlderWorkouts() async throws {
        let store = try await Self.store(newest: 12, older: 3)
        let resolver = PlaceResolver(store: store, requestInterval: .zero) { coordinate in
            coordinate.latitude > 49.2
                ? .nothingThere
                : .found(.init(label: "Langley BC", parts: nil))
        }
        // Batches of 5: the first two hold nothing nameable.
        await resolver.resolvePending(limit: 5)
        var named: [String?] = []
        for day in 12..<15 { named.append(try await store.item(id: "W\(day)")?.placeLabel) }
        #expect(named == ["Langley BC", "Langley BC", "Langley BC"])
    }
}
