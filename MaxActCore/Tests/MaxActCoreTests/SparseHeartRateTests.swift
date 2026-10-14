import Foundation
import Testing

@testable import MaxActCore

/// The Apple Workout app's heart rate arrives from Health Auto Export's workout export as one
/// averaged reading per ~10-minute chunk; `get_health_metrics` has every reading. Shapes below are
/// trimmed from live replies for a 2025-10-08 run (3 readings vs. 367).
@Suite struct SparseHeartRateTests {
    private static let start = "2025-10-08 12:00:00 -0700"
    private static let end = "2025-10-08 12:30:00 -0700"

    private static func reading(_ date: Date, _ bpm: Double) -> HeartRateSample {
        HeartRateSample(date: date, minimum: bpm, average: bpm, maximum: bpm)
    }

    @Test("fewer than one reading a minute is sparse; a short workout never is")
    func rule() {
        let t0 = Date(timeIntervalSince1970: 0)
        let three = (0..<3).map { Self.reading(t0.addingTimeInterval(Double($0) * 600), 150) }
        let everyFive = (0..<360).map { Self.reading(t0.addingTimeInterval(Double($0) * 5), 150) }
        #expect(WorkoutSeries.heartRateIsSparse(three, duration: 1800))
        #expect(!WorkoutSeries.heartRateIsSparse(everyFive, duration: 1800))
        #expect(WorkoutSeries.heartRateIsSparse([], duration: 1800))
        #expect(!WorkoutSeries.heartRateIsSparse([], duration: 90), "too short to judge")
    }

    /// The `get_workouts` reply: three averaged readings, as the export sends them.
    private static let sparseWorkout = MCPHTTPResponse.toolResult(payload: #"{"data":{"workouts":[{"id":"RUN","name":"Outdoor Run","#
        + #""start":"\#(start)","end":"\#(end)","duration":1800,"source":{"name":"MaxWatch7"},"heartRateData":["#
        + #"{"date":"2025-10-08 12:00:01 -0700","Min":139.7,"Avg":139.7,"Max":139.7,"units":"bpm"},"#
        + #"{"date":"2025-10-08 12:11:16 -0700","Min":153.4,"Avg":153.4,"Max":153.4,"units":"bpm"},"#
        + #"{"date":"2025-10-08 12:21:15 -0700","Min":157.2,"Avg":157.2,"Max":157.2,"units":"bpm"}]}]}}"#)

    /// The `get_health_metrics` reply: every 5 s from the watch, plus a reading from another
    /// device and one outside the workout, neither of which belongs.
    private static var denseMetrics: MCPHTTPResponse {
        var points = (0..<360).map { index in
            let seconds = index * 5
            let date = String(format: "2025-10-08 12:%02d:%02d -0700", seconds / 60, seconds % 60)
            return #"{"date":"\#(date)","Min":\#(120 + index % 40),"Avg":\#(120 + index % 40),"Max":\#(120 + index % 40),"source":"MaxWatch7"}"#
        }
        points.append(#"{"date":"2025-10-08 12:10:02 -0700","Min":60,"Avg":60,"Max":60,"source":"Polar H10"}"#)
        points.append(#"{"date":"2025-10-08 12:45:00 -0700","Min":90,"Avg":90,"Max":90,"source":"MaxWatch7"}"#)
        return .toolResult(payload: #"{"data":{"metrics":[{"name":"heart_rate","units":"count/min","data":["#
            + points.joined(separator: ",") + "]}]}}")
    }

    private static var tools: MCPHTTPResponse {
        .json(#"{"jsonrpc":"2.0","id":"2","result":{"tools":[{"name":"get_workouts"},{"name":"get_health_metrics"}]}}"#)
    }

    private static var workout: Workout {
        let parser = HAEDateParser()
        let start = try! parser.date(from: Self.start, field: "start"), end = try! parser.date(from: Self.end, field: "end")
        return Workout(id: "RUN", kind: .running, start: start, end: end, duration: 1800)
    }

    @Test("sparse export heart rate is replaced by the metrics tool's, from the workout's device and window")
    func fallback() async throws {
        let transport = MockTransport(responses: [.initialized, .json("{}"), Self.tools, Self.sparseWorkout, Self.denseMetrics])
        let source = HAEWorkoutSource(client: MCPClient(transport: transport, token: "t"))
        try await source.connect()
        let detail = try #require(try await source.fetchDetail(for: Self.workout))

        #expect(detail.series.heartRate.count == 360)
        #expect(!detail.series.heartRate.contains { $0.average == 60 }, "another device's reading")
        #expect(detail.series.heartRate.allSatisfy { $0.date <= Self.workout.end }, "a reading after the workout")
        #expect(HeartRateHistogram(detail.series.heartRate).total > 1700)

        let call = try #require(await transport.exchanges.last).params()
        #expect(call["name"] as? String == "get_health_metrics")
        let arguments = call["arguments"] as? [String: Any] ?? [:]
        #expect(arguments["metrics"] as? String == "heart_rate")
        #expect(arguments["interval"] as? String == "seconds")
        #expect(arguments["aggregate"] as? Bool == true)
    }

    @Test("dense export heart rate costs no second query")
    func noFallback() async throws {
        let dense = (0..<360).map { index in
            let seconds = index * 5
            return #"{"date":"\#(String(format: "2025-10-08 12:%02d:%02d -0700", seconds / 60, seconds % 60))","Avg":140,"units":"bpm"}"#
        }
        let reply = MCPHTTPResponse.toolResult(payload: #"{"data":{"workouts":[{"id":"RUN","name":"Outdoor Run","#
            + #""start":"\#(Self.start)","end":"\#(Self.end)","duration":1800,"heartRateData":["# + dense.joined(separator: ",") + "]}]}}")
        let transport = MockTransport(responses: [.initialized, .json("{}"), Self.tools, reply])
        let source = HAEWorkoutSource(client: MCPClient(transport: transport, token: "t"))
        try await source.connect()
        let detail = try #require(try await source.fetchDetail(for: Self.workout))
        #expect(detail.series.heartRate.count == 360)
        #expect(await transport.exchanges.filter { $0.method == "tools/call" }.count == 1)
    }

    @Test("stored workouts with sparse heart rate are marked for re-download; dense or HR-less ones aren't")
    func repair() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "SparseHeartRateTests-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let seriesStore = try SeriesStore(directory: root)
        let store = WorkoutStore(modelContainer: try WorkoutStore.container(inMemory: true))
        let t0 = Date(timeIntervalSince1970: 1_760_000_000)
        func item(_ id: String, readings: Int, every: TimeInterval, average: Double?) -> IngestedWorkout {
            IngestedWorkout(
                workout: Workout(id: id, kind: .running, start: t0, end: t0.addingTimeInterval(1800), duration: 1800,
                                 averageHeartRate: average),
                series: WorkoutSeries(workoutID: id, route: [], heartRate: (0..<readings).map {
                    Self.reading(t0.addingTimeInterval(Double($0) * every), 150)
                }, stepCount: [SeriesSample(date: t0, value: 1)])
            )
        }
        try await store.upsert([
            item("SPARSE", readings: 3, every: 600, average: 150),
            item("DENSE", readings: 360, every: 5, average: 150),
            item("NO-HR", readings: 1, every: 5, average: nil),
        ], seriesStore: seriesStore)

        let marked = try await store.markSparseHeartRateForRedownload(seriesStore: seriesStore)
        #expect(marked == ["SPARSE"])
        let needing = try await store.allItems().filter { !$0.hasDetail }.map(\.id)
        #expect(needing == ["SPARSE"])
    }

    @Test("an invalidated digest is rebuilt from the new series")
    func invalidate() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "SparseHeartRateTests-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let seriesStore = try SeriesStore(directory: root.appending(path: "Series"))
        let t0 = Date(timeIntervalSince1970: 0)
        try await seriesStore.save(WorkoutSeries(workoutID: "RUN", heartRate: [Self.reading(t0, 150)]))
        let cache = try RouteSketchCache(directory: root)
        #expect(await cache.digests(for: ["RUN"], seriesStore: seriesStore).first?.heartRate.total == 0)

        try await seriesStore.save(WorkoutSeries(workoutID: "RUN", heartRate: (0..<13).map {
            Self.reading(t0.addingTimeInterval(Double($0) * 5), 150)
        }))
        #expect(await cache.digests(for: ["RUN"], seriesStore: seriesStore).first?.heartRate.total == 0, "stale until told")
        await cache.invalidate(["RUN"])
        #expect(await cache.digests(for: ["RUN"], seriesStore: seriesStore).first?.heartRate.total == 60)
    }
}
