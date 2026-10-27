import Foundation
import MaxActCore
import Testing

@testable import MaxAct2

/// Issue 24: "Everything" goes back to 2000, weekly, through the real MCP client and decoder,
/// against a pretend phone.
@MainActor @Suite struct SyncEverythingTests {
    /// Answers the MCP handshake and `get_workouts` from a list of workout dates, and times out
    /// on a window holding more than `timeoutAbove` — the phone at ~2.4 s each against 600 s.
    actor PretendPhone: MCPTransport {
        let dates: [Date]
        let timeoutAbove: Int
        /// How long each `get_workouts` takes. Not cut short by cancellation, like a request
        /// already on its way to the phone.
        let delay: Duration
        private(set) var listCalls = 0
        private(set) var timeouts = 0
        private(set) var connections = 0

        init(dates: [Date], timeoutAbove: Int, delay: Duration = .zero) {
            self.dates = dates
            self.timeoutAbove = timeoutAbove
            self.delay = delay
        }

        static let format: DateFormatter = {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyy-MM-dd HH:mm:ss Z"
            return formatter
        }()

        func post(_ body: Data, headers: [String: String]) async throws -> MCPHTTPResponse {
            let message = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:]
            switch message["method"] as? String {
            case "initialize":
                connections += 1
                return Self.json(#"{"jsonrpc":"2.0","id":"1","result":{"protocolVersion":"2025-06-18","serverInfo":{"name":"Health Auto Export","version":"1.1.0"}}}"#,
                                 headers: ["Mcp-Session-Id": "S"])
            case "tools/list":
                return Self.json(#"{"jsonrpc":"2.0","id":"2","result":{"tools":[{"name":"get_workouts"}]}}"#)
            case "tools/call":
                listCalls += 1
                if delay > .zero { await Task.detached { [delay] in try? await Task.sleep(for: delay) }.value }
                let arguments = (message["params"] as? [String: Any])?["arguments"] as? [String: Any] ?? [:]
                guard let start = (arguments["start"] as? String).flatMap(Self.format.date(from:)),
                      let end = (arguments["end"] as? String).flatMap(Self.format.date(from:))
                else { return Self.json("{}", status: 400) }
                let inside = dates.filter { $0 >= start && $0 < end }
                if inside.count > timeoutAbove {
                    timeouts += 1
                    throw URLError(.timedOut)
                }
                let workouts = inside.map { date in
                    [
                        "id": "W-\(Int(date.timeIntervalSince1970))",
                        "name": "Outdoor Run",
                        "start": Self.format.string(from: date),
                        "end": Self.format.string(from: date.addingTimeInterval(1800)),
                        "duration": 1800.0,
                    ] as [String: Any]
                }
                let payload = String(data: try JSONSerialization.data(withJSONObject: ["data": ["workouts": workouts]]), encoding: .utf8)!
                let result: [String: Any] = ["jsonrpc": "2.0", "id": "3", "result": ["content": [["type": "text", "text": payload]]]]
                return MCPHTTPResponse(statusCode: 200, body: try JSONSerialization.data(withJSONObject: result),
                                       headers: ["content-type": "application/json"])
            default:
                return Self.json("{}", status: 202)
            }
        }

        static func json(_ text: String, status: Int = 200, headers: [String: String] = [:]) -> MCPHTTPResponse {
            MCPHTTPResponse(statusCode: status, body: Data(text.utf8),
                            headers: headers.reduce(into: ["content-type": "application/json"]) { $0[$1.key.lowercased()] = $1.value })
        }
    }

    static let end = Date(timeIntervalSince1970: 1_761_350_400)   // 2025-10-25
    static let day: TimeInterval = 86_400

    /// A run every other day for the last 200 days; nothing for years; then 20 runs from 2011,
    /// before Health existed — a history imported from Strava, the case the user asked about.
    static let history: [Date] = {
        let recent = (0..<100).map { end.addingTimeInterval(-Double($0) * 2 * day - 3600) }
        let importedEnd = Date(timeIntervalSince1970: 1_304_208_000)   // 2011-05-01
        let imported = (0..<20).map { importedEnd.addingTimeInterval(-Double($0) * 3 * day) }
        return recent + imported
    }()

    private func model() -> AppModel {
        let suite = "SyncEverythingTests"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return AppModel.inMemoryFallback(settings: AppSettings(defaults: defaults), resolvesPlaces: false,
                                         stravaSecrets: InMemorySecretStore())
    }

    @Test func everythingFindsTheWholeHistoryBackTo2000() async throws {
        let phone = PretendPhone(dates: Self.history, timeoutAbove: 40)
        let model = model()
        await model.syncEverything(source: HAEWorkoutSource(client: MCPClient(transport: phone, token: "t")), end: Self.end)

        #expect(model.syncStatus == .listed(found: Self.history.count, unreadable: 0), "\(model.syncStatus)")
        #expect(model.items.count == Self.history.count)
        // Every week back to 2000, each asked once.
        let weeks = SyncPlanner.windows(from: SyncPlanner.everythingStart, to: Self.end).count
        #expect(await phone.listCalls == weeks)
    }

    /// A week that times out fails the sync, reported like any other failure.
    @Test func aWeekThatTimesOutFailsTheSync() async {
        let dense = (0..<50).map { Self.end.addingTimeInterval(-Double($0) * 3600 - 60) }
        let phone = PretendPhone(dates: dense, timeoutAbove: 40)
        let model = model()
        await model.syncEverything(source: HAEWorkoutSource(client: MCPClient(transport: phone, token: "t")), end: Self.end)
        guard case .failed = model.syncStatus else {
            Issue.record("expected a failure, got \(model.syncStatus)")
            return
        }
    }
}
