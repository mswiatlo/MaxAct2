import Foundation
import Testing

@testable import MaxActCore

@Suite struct ConnectionCheckTests {
    private static let tools = MCPHTTPResponse.json(#"{"jsonrpc":"2.0","id":"2","result":{"tools":[{"name":"get_workouts"}]}}"#)
    private static let twoWorkouts = MCPHTTPResponse.toolResult(payload: #"{"data":{"workouts":["#
        + #"{"id":"A","name":"Running","start":"2026-10-06 07:00:00 -0700","end":"2026-10-06 07:30:00 -0700","duration":1800},"#
        + #"{"id":"B","name":"Cycling","start":"2026-10-08 07:00:00 -0700","end":"2026-10-08 07:30:00 -0700","duration":1800}"#
        + #"]}}"#)

    private func source(_ responses: [MCPHTTPResponse]) -> (HAEWorkoutSource, MockTransport) {
        let transport = MockTransport(responses: responses)
        return (HAEWorkoutSource(client: MCPClient(transport: transport, token: "t")), transport)
    }

    @Test("a working connection reports the server and recent workouts, having called the tool")
    func connected() async {
        let (source, transport) = source([.initialized, .json("{}"), Self.tools, Self.twoWorkouts])
        let check = await ConnectionCheck.run(source)
        #expect(check == .connected(server: "Health Auto Export 1.1.0", recentWorkouts: 2))
        #expect(check.succeeded)
        #expect(check.summary.contains("2 workouts in the last two weeks"))
        #expect(await transport.exchanges.map(\.method) == ["initialize", "notifications/initialized", "tools/list", "tools/call"])
    }

    @Test("connected but empty points at Health's sharing settings")
    func connectedButEmpty() async {
        let (source, _) = source([.initialized, .json("{}"), Self.tools, .toolResult(payload: #"{"data":{"workouts":[]}}"#)])
        let check = await ConnectionCheck.run(source)
        #expect(check.succeeded)
        #expect(check.summary.contains("Sharing ▸ Apps"))
    }

    @Test("a rejected token is reported as such")
    func rejected() async {
        let (source, _) = source([.json("nope", status: 401)])
        let check = await ConnectionCheck.run(source)
        #expect(check == .failed(.tokenRejected))
        #expect(!check.succeeded)
    }

    @Test("an unreachable phone fails within the test's own timeout, not the sync's ten minutes")
    func unreachableIsQuick() async throws {
        let source = HAEWorkoutSource(endpoint: try #require(MCPEndpoint("10.255.255.1")), token: "t", timeout: 2)
        let clock = ContinuousClock()
        var check: ConnectionCheck?
        let elapsed = await clock.measure { check = await ConnectionCheck.run(source) }
        #expect(check == .failed(.phoneUnreachable))
        #expect(elapsed < .seconds(10), "took \(elapsed)")
    }
}
