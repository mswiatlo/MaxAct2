import Foundation

public struct MCPHTTPResponse: Sendable {
    public let statusCode: Int
    public let body: Data
    /// Lower-cased header names, because HTTP header case is not guaranteed and we depend on
    /// reading `Mcp-Session-Id` back out.
    public let headers: [String: String]

    public init(statusCode: Int, body: Data, headers: [String: String]) {
        self.statusCode = statusCode
        self.body = body
        self.headers = headers.reduce(into: [:]) { $0[$1.key.lowercased()] = $1.value }
    }
}

/// The HTTP boundary, abstracted so ``MCPClient`` can be tested without a phone on the network.
public protocol MCPTransport: Sendable {
    func post(_ body: Data, headers: [String: String]) async throws -> MCPHTTPResponse
}

public struct URLSessionMCPTransport: MCPTransport {
    private let endpoint: URL
    private let session: URLSession

    /// - Parameter timeout: generous by necessity. The phone answers at ~2.4 s per workout, so a
    ///   90-day window measured 234 s — far past `URLSession`'s 60 s default, which would abort
    ///   every large request.
    public init(endpoint: MCPEndpoint, timeout: TimeInterval = 600) {
        self.endpoint = endpoint.url

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        configuration.waitsForConnectivity = false
        session = URLSession(configuration: configuration)
    }

    public func post(_ body: Data, headers: [String: String]) async throws -> MCPHTTPResponse {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.httpBody = body
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw MCPError.transport("response was not HTTP")
        }
        let headerFields = http.allHeaderFields.reduce(into: [String: String]()) { result, pair in
            if let name = pair.key as? String, let value = pair.value as? String {
                result[name] = value
            }
        }
        return MCPHTTPResponse(statusCode: http.statusCode, body: data, headers: headerFields)
    }
}
