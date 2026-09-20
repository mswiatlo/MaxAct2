import Foundation
import Testing

@testable import MaxActCore

/// Records what the client sent and replays canned responses, so the whole MCP handshake can be
/// verified without a phone on the network.
actor MockTransport: MCPTransport {
    /// Only Sendable pieces are retained; `Any`-typed JSON cannot cross the actor boundary in
    /// Swift 6, so the body is kept as text and re-parsed by whoever needs it.
    struct Exchange: Sendable {
        let method: String
        let headers: [String: String]
        let bodyJSON: String

        func params() -> [String: Any] {
            let object = (try? JSONSerialization.jsonObject(with: Data(bodyJSON.utf8))) as? [String: Any]
            return object?["params"] as? [String: Any] ?? [:]
        }
    }

    private var responses: [MCPHTTPResponse]
    private(set) var exchanges: [Exchange] = []

    init(responses: [MCPHTTPResponse]) {
        self.responses = responses
    }

    func post(_ body: Data, headers: [String: String]) async throws -> MCPHTTPResponse {
        let object = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:]
        exchanges.append(Exchange(
            method: object["method"] as? String ?? "",
            headers: headers,
            bodyJSON: String(data: body, encoding: .utf8) ?? ""
        ))
        guard !responses.isEmpty else { return .json("{}") }
        return responses.removeFirst()
    }
}

extension MCPHTTPResponse {
    static func json(_ text: String, status: Int = 200, headers: [String: String] = [:]) -> MCPHTTPResponse {
        MCPHTTPResponse(
            statusCode: status,
            body: Data(text.utf8),
            headers: headers.merging(["Content-Type": "application/json"]) { a, _ in a }
        )
    }

    /// The handshake reply: the session id lives in the headers, not the body.
    static var initialized: MCPHTTPResponse {
        .json(
            #"{"jsonrpc":"2.0","id":"1","result":{"protocolVersion":"2025-06-18","serverInfo":{"name":"Health Auto Export","version":"1.1.0"}}}"#,
            headers: ["Mcp-Session-Id": "SESSION-123"]
        )
    }

    /// Tool results wrap the real payload as a JSON *string* inside a content array.
    static func toolResult(payload: String) -> MCPHTTPResponse {
        let escaped = String(data: try! JSONSerialization.data(withJSONObject: [payload], options: .fragmentsAllowed), encoding: .utf8)!
            .dropFirst().dropLast()  // strip the array brackets, keeping the quoted string
        return .json(#"{"jsonrpc":"2.0","id":"2","result":{"content":[{"type":"text","text":\#(escaped)}]}}"#)
    }
}

@Suite struct MCPClientTests {

    @Test("the handshake captures the session id and reports the server")
    func handshake() async throws {
        let transport = MockTransport(responses: [.initialized, .json("{}")])
        let client = MCPClient(transport: transport, token: "secret")
        let info = try await client.connect()

        #expect(info.name == "Health Auto Export")
        #expect(info.version == "1.1.0")

        let exchanges = await transport.exchanges
        #expect(exchanges.first?.method == "initialize")
        #expect(exchanges.first?.headers["Authorization"] == "Bearer secret")
        #expect(exchanges.first?.headers["Accept"]?.contains("text/event-stream") == true)
        #expect(exchanges.count == 2)
        #expect(exchanges.last?.method == "notifications/initialized")
    }

    @Test("every request after the handshake carries the session id")
    func sessionIDIsPropagated() async throws {
        let transport = MockTransport(responses: [
            .initialized, .json("{}"), .toolResult(payload: #"{"data":{"workouts":[]}}"#),
        ])
        let client = MCPClient(transport: transport, token: nil)
        try await client.connect()
        _ = try await client.callTool("get_workouts", arguments: ["start": "x"])

        let exchanges = await transport.exchanges
        // The initialize request cannot carry one; everything after it must.
        #expect(exchanges[0].headers["Mcp-Session-Id"] == nil)
        #expect(exchanges[1].headers["Mcp-Session-Id"] == "SESSION-123")
        #expect(exchanges[2].headers["Mcp-Session-Id"] == "SESSION-123")
        #expect(exchanges[2].method == "tools/call")
    }

    @Test("a handshake that returns no session id fails clearly rather than later")
    func missingSessionIDIsCaught() async throws {
        let transport = MockTransport(responses: [.json(#"{"result":{}}"#)])
        let client = MCPClient(transport: transport, token: nil)
        await #expect(throws: MCPError.missingSessionID) { try await client.connect() }
    }

    @Test("a JSON-RPC error becomes a typed error, not a silent empty result")
    func rpcErrorSurfaces() async throws {
        let transport = MockTransport(responses: [
            .json(#"{"jsonrpc":"2.0","id":"1","error":{"code":-32600,"message":"Missing or invalid Mcp-Session-Id"}}"#)
        ])
        let client = MCPClient(transport: transport, token: nil)
        await #expect(throws: MCPError.rpc(code: -32600, message: "Missing or invalid Mcp-Session-Id")) {
            try await client.connect()
        }
    }

    @Test("an HTTP failure carries the status and body")
    func httpErrorSurfaces() async throws {
        let transport = MockTransport(responses: [.json("nope", status: 401)])
        let client = MCPClient(transport: transport, token: "stale")
        await #expect(throws: MCPError.http(status: 401, body: "nope")) { try await client.connect() }
    }

    @Test("the tool result's doubly-encoded payload is unwrapped")
    func toolResultUnwrapping() async throws {
        let payload = #"{"data":{"workouts":[{"id":"A","name":"Running","start":"2024-02-06 07:00:00 -0700","end":"2024-02-06 07:30:00 -0700","duration":1800}]}}"#
        let transport = MockTransport(responses: [.initialized, .json("{}"), .toolResult(payload: payload)])
        let client = MCPClient(transport: transport, token: nil)
        try await client.connect()

        let data = try await client.callTool("get_workouts", arguments: [:])
        let result = try HAEWorkoutDecoder().decode(data)
        #expect(result.workouts.count == 1)
        #expect(result.workouts.first?.workout.kind == .running)
    }

    @Test("a tool that reports isError throws instead of decoding nonsense")
    func toolErrorIsDetected() {
        let result: [String: Any] = [
            "isError": true,
            "content": [["type": "text", "text": "date range too large"]],
        ]
        #expect(throws: MCPError.rpc(code: 0, message: "date range too large")) {
            try MCPClient.unwrapToolResult(result)
        }
    }

    @Test("a server-sent-events response body is unwrapped to its JSON payload")
    func serverSentEventsAreHandled() {
        let sse = "event: message\ndata: {\"jsonrpc\":\"2.0\",\"result\":{\"ok\":true}}\n\n"
        let response = MCPHTTPResponse(
            statusCode: 200,
            body: Data(sse.utf8),
            headers: ["Content-Type": "text/event-stream"]
        )
        let body = MCPClient.jsonBody(from: response)
        let object = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
        #expect((object?["result"] as? [String: Any])?["ok"] as? Bool == true)
    }

    @Test("header lookup is case-insensitive, since HTTP does not guarantee casing")
    func headerCaseInsensitivity() {
        let response = MCPHTTPResponse(statusCode: 200, body: Data(), headers: ["MCP-SESSION-ID": "abc"])
        #expect(response.headers["mcp-session-id"] == "abc")
    }
}
