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
        #expect(check.summary.contains("2 workouts in the last week"))
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

    /// A phone that never answers, in place of a real unroutable address: that depended on this
    /// Mac's network, VPN and sandbox, and could fail some other way (issue 43).
    actor SilentPhone: MCPTransport {
        func post(_ body: Data, headers: [String: String]) async throws -> MCPHTTPResponse {
            try await Task.sleep(for: .seconds(60))
            throw URLError(.timedOut)
        }
    }

    @Test("an unreachable phone fails at the handshake's deadline, not the listing's long timeout")
    func unreachableIsQuick() async throws {
        let source = HAEWorkoutSource(client: MCPClient(transport: SilentPhone(), token: "t"))
        let clock = ContinuousClock()
        var check: ConnectionCheck?
        let elapsed = await clock.measure { check = await ConnectionCheck.run(source, connectDeadline: 2) }
        #expect(check == .failed(.phoneUnreachable))
        #expect(elapsed < .seconds(10), "took \(elapsed)")
    }

    /// The bug the user saw: a real phone takes ~20 s to list two weeks, and a single short timeout
    /// declared it unreachable while it was still answering. The listing isn't under the handshake's
    /// deadline.
    @Test("a slow listing after a quick handshake still succeeds")
    func slowListingSucceeds() async {
        let transport = SlowListingTransport(responses: [.initialized, .json("{}"), Self.tools, Self.twoWorkouts],
                                             listingDelay: .milliseconds(1500))
        let source = HAEWorkoutSource(client: MCPClient(transport: transport, token: "t"))
        let check = await ConnectionCheck.run(source, connectDeadline: 1)
        #expect(check.succeeded, "got \(check)")
    }
}

/// Answers like `MockTransport`, but slowly for `tools/call` — the listing — as a real phone does.
private actor SlowListingTransport: MCPTransport {
    private var responses: [MCPHTTPResponse]
    private let listingDelay: Duration

    init(responses: [MCPHTTPResponse], listingDelay: Duration) {
        self.responses = responses
        self.listingDelay = listingDelay
    }

    func post(_ body: Data, headers: [String: String]) async throws -> MCPHTTPResponse {
        let method = ((try? JSONSerialization.jsonObject(with: body)) as? [String: Any])?["method"] as? String
        if method == "tools/call" { try await Task.sleep(for: listingDelay) }
        return responses.isEmpty ? .json("{}") : responses.removeFirst()
    }
}
