import Foundation

public enum MCPError: Error, CustomStringConvertible, Equatable {
    case transport(String)
    case http(status: Int, body: String)
    /// A JSON-RPC error object. `-32600 Missing or invalid Mcp-Session-Id` is the one you get for
    /// skipping the handshake.
    case rpc(code: Int, message: String)
    case missingSessionID
    case malformedResult(String)

    public var description: String {
        switch self {
        case .transport(let detail): "transport failure: \(detail)"
        case .http(let status, let body): "HTTP \(status): \(body.prefix(200))"
        case .rpc(let code, let message): "MCP error \(code): \(message)"
        case .missingSessionID:
            "server did not return an Mcp-Session-Id; the handshake did not complete"
        case .malformedResult(let detail): "unexpected result shape: \(detail)"
        }
    }
}

/// A minimal client for **MCP Streamable HTTP**, which is what Health Auto Export speaks on port
/// 9000 — not the simplified `callTool` shape its help pages describe. That shape belongs to the
/// TCP transport and is rejected here with `-32600`.
///
/// The sequence, established by measurement in Phase 1:
/// 1. `initialize`, and read `Mcp-Session-Id` from the **response headers**.
/// 2. Send the `notifications/initialized` notification.
/// 3. `tools/list` / `tools/call` — standard MCP method names.
///
/// An actor because the session id is mutable state shared across concurrent calls, and because
/// serialising requests is desirable anyway: the phone answers one query at a time.
public actor MCPClient {
    private let transport: any MCPTransport
    private let token: String?
    private var sessionID: String?
    private var nextRequestID = 1

    public static let protocolVersion = "2025-06-18"

    public init(transport: any MCPTransport, token: String?) {
        self.transport = transport
        self.token = token
    }

    public init(host: String, port: Int = 9000, token: String?, timeout: TimeInterval = 600) {
        self.init(transport: URLSessionMCPTransport(host: host, port: port, timeout: timeout), token: token)
    }

    public struct ServerInfo: Sendable, Equatable {
        public let name: String
        public let version: String
        public let protocolVersion: String
    }

    /// Performs the handshake. Safe to call again to re-establish a dropped session — which is the
    /// normal case, since the server dies whenever HAE is backgrounded.
    @discardableResult
    public func connect() async throws -> ServerInfo {
        sessionID = nil
        let response = try await send(
            method: "initialize",
            params: [
                "protocolVersion": Self.protocolVersion,
                "capabilities": [:],
                "clientInfo": ["name": "MaxAct", "version": "1.0"],
            ],
            expectsResult: true
        )
        guard let sessionID, !sessionID.isEmpty else { throw MCPError.missingSessionID }

        // A notification: no id, no response expected.
        _ = try? await send(method: "notifications/initialized", params: [:], isNotification: true)

        let info = response as? [String: Any]
        let server = info?["serverInfo"] as? [String: Any]
        return ServerInfo(
            name: server?["name"] as? String ?? "unknown",
            version: server?["version"] as? String ?? "unknown",
            protocolVersion: info?["protocolVersion"] as? String ?? Self.protocolVersion
        )
    }

    public func listToolNames() async throws -> [String] {
        let result = try await send(method: "tools/list", params: [:], expectsResult: true)
        guard let tools = (result as? [String: Any])?["tools"] as? [[String: Any]] else {
            throw MCPError.malformedResult("tools/list did not return a tools array")
        }
        return tools.compactMap { $0["name"] as? String }
    }

    /// Calls a tool and returns the **decoded payload**, having peeled both the MCP content
    /// envelope and the JSON-in-a-string that sits inside it.
    public func callTool(_ name: String, arguments: [String: Any]) async throws -> Data {
        let result = try await send(
            method: "tools/call",
            params: ["name": name, "arguments": arguments],
            expectsResult: true
        )
        return try Self.unwrapToolResult(result)
    }

    /// Tool results arrive as `{"content": [{"type": "text", "text": "<json>"}]}`, where `text` is
    /// itself a JSON document that has to be parsed again.
    static func unwrapToolResult(_ result: Any?) throws -> Data {
        guard let object = result as? [String: Any] else {
            throw MCPError.malformedResult("tool result was not an object")
        }
        if let isError = object["isError"] as? Bool, isError {
            let text = (object["content"] as? [[String: Any]])?.first?["text"] as? String
            throw MCPError.rpc(code: 0, message: text ?? "tool reported an error")
        }
        guard let content = object["content"] as? [[String: Any]] else {
            throw MCPError.malformedResult("tool result had no content array")
        }
        for item in content where item["type"] as? String == "text" {
            if let text = item["text"] as? String { return Data(text.utf8) }
        }
        throw MCPError.malformedResult("tool result contained no text content")
    }

    // MARK: - JSON-RPC plumbing

    @discardableResult
    private func send(
        method: String,
        params: [String: Any],
        expectsResult: Bool = false,
        isNotification: Bool = false
    ) async throws -> Any? {
        var message: [String: Any] = ["jsonrpc": "2.0", "method": method, "params": params]
        if !isNotification {
            message["id"] = String(nextRequestID)
            nextRequestID += 1
        }

        var headers = [
            "Content-Type": "application/json",
            // The spec allows the server to answer either way; HAE was measured returning plain
            // JSON, but advertising both keeps us compliant and SSE is handled below.
            "Accept": "application/json, text/event-stream",
        ]
        if let token { headers["Authorization"] = "Bearer \(token)" }
        if let sessionID { headers["Mcp-Session-Id"] = sessionID }

        let response = try await transport.post(
            try JSONSerialization.data(withJSONObject: message), headers: headers
        )

        if let returned = response.headers["mcp-session-id"] { sessionID = returned }

        guard (200..<300).contains(response.statusCode) else {
            throw MCPError.http(
                status: response.statusCode,
                body: String(data: response.body, encoding: .utf8) ?? "<binary>"
            )
        }
        if isNotification || response.body.isEmpty { return nil }

        let payload = Self.jsonBody(from: response)
        guard let envelope = try JSONSerialization.jsonObject(with: payload) as? [String: Any] else {
            throw MCPError.malformedResult("response was not a JSON object")
        }
        if let error = envelope["error"] as? [String: Any] {
            throw MCPError.rpc(
                code: error["code"] as? Int ?? 0,
                message: error["message"] as? String ?? "unknown error"
            )
        }
        guard !expectsResult || envelope["result"] != nil else {
            throw MCPError.malformedResult("no result for \(method)")
        }
        return envelope["result"]
    }

    /// Streamable HTTP may answer with `text/event-stream`. Take the last `data:` line, which is
    /// the complete JSON-RPC message.
    static func jsonBody(from response: MCPHTTPResponse) -> Data {
        guard response.headers["content-type"]?.contains("text/event-stream") == true,
              let text = String(data: response.body, encoding: .utf8)
        else { return response.body }

        let payloads = text
            .split(separator: "\n", omittingEmptySubsequences: true)
            .filter { $0.hasPrefix("data:") }
            .map { $0.dropFirst("data:".count).trimmingCharacters(in: .whitespaces) }
        return Data((payloads.last ?? "").utf8)
    }
}
