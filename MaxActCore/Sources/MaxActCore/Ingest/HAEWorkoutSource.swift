import Foundation

/// The chosen ingest path: Health Auto Export's MCP server, pulled by the Mac.
///
/// Two request shapes, per the Phase 1 decision:
///
/// | | `includeRoutes` | `metadataAggregation` | cost |
/// |---|---|---|---|
/// | list | `false` | `"minutes"` | ~46 KB and ~2.4 s per workout |
/// | detail | `true` | `"seconds"` | ~2.5 MB and ~2.4 s per workout |
///
/// Note `includeMetadata` stays `true` even for the list pass. Turning it off saves almost nothing
/// — time scales with workout count, not payload — and it drops `avgHeartRate`, `maxHeartRate`,
/// `isIndoor` and `location`, all of which the list view shows.
public struct HAEWorkoutSource: WorkoutSource {
    public enum Aggregation: String, Sendable {
        case minutes, seconds
    }

    private let client: MCPClient
    private let decoder = HAEWorkoutDecoder()
    private let toolName: String

    public init(client: MCPClient, toolName: String = "get_workouts") {
        self.client = client
        self.toolName = toolName
    }

    public init(endpoint: MCPEndpoint, token: String?) {
        self.init(client: MCPClient(endpoint: endpoint, token: token))
    }

    /// Convenience for anything holding raw user input. `nil` when the text can't be parsed —
    /// the caller reports that rather than the app trapping.
    public init?(address: String, token: String?) {
        guard let endpoint = MCPEndpoint(address) else { return nil }
        self.init(endpoint: endpoint, token: token)
    }

    /// Handshake, and confirm the server actually offers the tool we intend to call. Better a
    /// clear error naming the available tools than a bare `-32602` mid-backfill.
    @discardableResult
    public func connect() async throws -> MCPClient.ServerInfo {
        let info = try await client.connect()
        let tools = try await client.listToolNames()
        guard tools.contains(toolName) else {
            throw MCPError.malformedResult(
                "server \(info.name) \(info.version) has no '\(toolName)'; it offers: \(tools.sorted().joined(separator: ", "))"
            )
        }
        return info
    }

    public func listWorkouts(in window: SyncWindow) async throws -> HAEWorkoutDecoder.Result {
        let payload = try await client.callTool(
            toolName,
            arguments: arguments(start: window.start, end: window.end, routes: false, aggregation: .minutes)
        )
        return try decoder.decode(payload)
    }

    public func fetchDetail(for workout: Workout) async throws -> IngestedWorkout? {
        // Widen the window slightly: `start`/`end` are the workout's own bounds, and asking for
        // exactly those risks a boundary-exclusive server dropping the very workout we want.
        let payload = try await client.callTool(
            toolName,
            arguments: arguments(
                start: workout.start.addingTimeInterval(-60),
                end: workout.end.addingTimeInterval(60),
                routes: true,
                aggregation: .seconds
            )
        )
        let result = try decoder.decode(payload)
        if let failure = result.failures.first(where: { $0.workoutID == workout.id }) {
            throw failure.underlying
        }
        // A narrow window can still return neighbours; take the one we asked for.
        return result.workouts.first { $0.workout.id == workout.id }
    }

    private func arguments(
        start: Date, end: Date, routes: Bool, aggregation: Aggregation
    ) -> [String: Any] {
        [
            "start": HAEDateFormatting.string(from: start),
            "end": HAEDateFormatting.string(from: end),
            "includeRoutes": routes,
            "includeMetadata": true,
            "metadataAggregation": aggregation.rawValue,
        ]
    }
}

public enum HAEDateFormatting {
    /// HAE accepts and emits `yyyy-MM-dd HH:mm:ss Z`. Requests are formatted in the Mac's current
    /// zone; the explicit offset makes that unambiguous regardless.
    public static func string(from date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = MaxActCore.haeDateFormat
        return formatter.string(from: date)
    }
}
