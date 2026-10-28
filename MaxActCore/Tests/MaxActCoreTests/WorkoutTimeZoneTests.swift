import Foundation
import Testing

@testable import MaxActCore

/// Follow-up from 38: a workout is named by the local time where it happened.
@Suite struct WorkoutTimeZoneTests {
    /// The real case: a run in Switzerland at 07:02 local, which is 22:02 the evening before in
    /// Vancouver — and HAE reports it as `2025-10-20 22:01:58 -0700` (measured).
    static let swissRun = Workout(id: "R", kind: .running, start: ISO8601DateFormatter().date(from: "2025-10-21T05:01:58Z")!,
                                  end: ISO8601DateFormatter().date(from: "2025-10-21T05:40:00Z")!, duration: 2_280)

    @Test("the Swiss morning run is a Morning Run in its own zone, a Night Run in Vancouver's")
    func swissRun() {
        let zone = WorkoutTimeZone.zone(start: Self.swissRun.start, own: "Europe/Zurich", others: [])
        #expect(StravaUploader.activityName(for: Self.swissRun, in: zone!) == "Morning Run")
        #expect(StravaUploader.activityName(for: Self.swissRun, in: TimeZone(identifier: "America/Vancouver")!) == "Night Run")
    }

    @Test("an indoor workout borrows the nearest zone within a day, and no further")
    func borrowing() {
        let start = Self.swissRun.start
        let others = [(start: start.addingTimeInterval(-3 * 3600), zone: "Europe/Zurich"),
                      (start: start.addingTimeInterval(-20 * 3600), zone: "America/Vancouver")]
        #expect(WorkoutTimeZone.zone(start: start, own: nil, others: others)?.identifier == "Europe/Zurich")
        #expect(WorkoutTimeZone.zone(start: start, own: nil, others: [(start: start.addingTimeInterval(-30 * 3600), zone: "Europe/Zurich")]) == nil,
                "a day and a bit away is too far: the flight home may be in between")
        #expect(WorkoutTimeZone.zone(start: start, own: "America/Chicago", others: others)?.identifier == "America/Chicago",
                "its own zone wins")
        #expect(WorkoutTimeZone.zone(start: start, own: "Not/AZone", others: []) == nil)
    }

    @Test("a place's zone is stored, shown on the row, and an older resolution asks again")
    func stored() async throws {
        let store = WorkoutStore(modelContainer: try WorkoutStore.container(inMemory: true))
        let folder = FileManager.default.temporaryDirectory.appending(path: "WorkoutTimeZoneTests-\(UUID())")
        defer { try? FileManager.default.removeItem(at: folder) }
        let series = try SeriesStore(directory: folder)
        let route = (0..<3).map { RoutePoint(coordinate: Coordinate(latitude: 46.2, longitude: 6.14 + Double($0) * 0.0001),
                                             timestamp: Self.swissRun.start.addingTimeInterval(Double($0))) }
        let workout = Workout(id: "R", kind: .running, start: Self.swissRun.start, end: Self.swissRun.end,
                              duration: 2_280, hasRoute: true)
        try await store.upsert([IngestedWorkout(workout: workout, series: WorkoutSeries(workoutID: "R", route: route))],
                               seriesStore: series)
        #expect(try await store.itemsNeedingPlace().map(\.id) == ["R"])

        try await store.setPlace(label: "Geneva", timeZone: "Europe/Zurich", for: "R")
        #expect(try await store.item(id: "R")?.placeTimeZone == "Europe/Zurich")
        #expect(try await store.itemsNeedingPlace().isEmpty)
    }
}
