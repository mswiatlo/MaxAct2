import Foundation
import Testing

@testable import MaxActCore

/// What HAE's UTC offset means (follow-up from 38): the zone the workout was recorded in, the
/// phone's zone, or one fixed offset. Asks for three known workouts and prints the raw `start`
/// strings — nothing else from the reply. Run against a real phone:
///
/// ```
/// MAXACT_LIVE_HOST=https://<phone>:9000 MAXACT_LIVE_TOKEN=<token> MAXACT_LIVE_CA=<pem> \
///   swift test --filter LiveTimeZoneTests
/// ```
@Suite(.enabled(if: LiveConfiguration.isConfigured))
struct LiveTimeZoneTests {
    /// (what it is, UTC start, offset if the recording's zone is used)
    static let probes: [(String, String, String)] = [
        ("Vancouver ride, December", "2025-12-02T19:13:56Z", "-0800"),
        ("Switzerland run, October", "2025-10-21T05:01:58Z", "+0200"),
        ("Illinois walk, December", "2025-12-13T17:44:30Z", "-0600"),
    ]

    @Test("print the offsets HAE gives three known workouts")
    func offsets() async throws {
        let credentials = try #require(LiveConfiguration.credentials)
        let ca = try LiveTLSConfiguration.caFile.map { try PinnedCA(contents: Data(contentsOf: $0)) }
        let endpoint = try #require(MCPEndpoint(credentials.host))
        let client = MCPClient(endpoint: endpoint, token: credentials.token, pinnedCA: endpoint.isHTTPS ? ca?.certificate : nil)
        _ = try await client.connect()
        let iso = ISO8601DateFormatter()
        for (label, utc, expected) in Self.probes {
            let start = try #require(iso.date(from: utc))
            let payload = try await client.callTool("get_workouts", arguments: [
                "start": HAEDateFormatting.string(from: start.addingTimeInterval(-120)),
                "end": HAEDateFormatting.string(from: start.addingTimeInterval(120)),
                "includeRoutes": false, "includeMetadata": false, "metadataAggregation": "minutes",
            ])
            let json = try JSONSerialization.jsonObject(with: payload) as? [String: Any]
            let workouts = ((json?["data"] as? [String: Any])?["workouts"] as? [[String: Any]]) ?? []
            let starts = workouts.compactMap { $0["start"] as? String }
            print("OFFSET \(label): HAE says \(starts) — the recording's zone would be \(expected)")
            // With metadata: does anything carry the recording's zone? Keys only, plus any value
            // whose key mentions a zone.
            let full = try await client.callTool("get_workouts", arguments: [
                "start": HAEDateFormatting.string(from: start.addingTimeInterval(-120)),
                "end": HAEDateFormatting.string(from: start.addingTimeInterval(120)),
                "includeRoutes": false, "includeMetadata": true, "metadataAggregation": "minutes",
            ])
            let fullJSON = try JSONSerialization.jsonObject(with: full) as? [String: Any]
            for workout in ((fullJSON?["data"] as? [String: Any])?["workouts"] as? [[String: Any]]) ?? [] {
                print("KEYS \(label): \(workout.keys.sorted())")
                if let metadata = workout["metadata"] as? [String: Any] {
                    print("METADATA KEYS \(label): \(metadata.keys.sorted())")
                    for (key, value) in metadata where key.lowercased().contains("zone") { print("ZONE \(key) = \(value)") }
                }
                for (key, value) in workout where key.lowercased().contains("zone") { print("ZONE \(key) = \(value)") }
            }
        }
    }
}
