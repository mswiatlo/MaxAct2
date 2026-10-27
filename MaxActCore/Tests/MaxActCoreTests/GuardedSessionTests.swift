import Foundation
import Testing

@testable import MaxActCore

/// Issue 47: neither link follows a redirect (which would re-send the bearer token elsewhere),
/// and a reply can't grow without bound.
@Suite(.serialized) struct GuardedSessionTests {
    /// Answers from a script keyed by host, and records every request it sees.
    final class StubProtocol: URLProtocol, @unchecked Sendable {
        struct Reply: Sendable {
            var status = 200
            var headers: [String: String] = [:]
            var body = Data()
        }

        nonisolated(unsafe) static var replies: [String: Reply] = [:]
        nonisolated(unsafe) static var seen: [URLRequest] = []
        static let lock = NSLock()

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            let reply = Self.lock.withLock {
                Self.seen.append(request)
                return Self.replies[request.url?.host() ?? ""] ?? Reply(status: 404)
            }
            let response = HTTPURLResponse(url: request.url!, statusCode: reply.status,
                                           httpVersion: "HTTP/1.1", headerFields: reply.headers)!
            if (300..<400).contains(reply.status), let location = reply.headers["Location"], let target = URL(string: location) {
                client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: target), redirectResponse: response)
            }
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            // In pieces, as a network would deliver it.
            var offset = 0
            while offset < reply.body.count {
                let end = min(offset + 1024, reply.body.count)
                client?.urlProtocol(self, didLoad: reply.body.subdata(in: offset..<end))
                offset = end
            }
            client?.urlProtocolDidFinishLoading(self)
        }

        override func stopLoading() {}

        static func reset(_ replies: [String: Reply]) {
            lock.withLock { self.replies = replies; seen = [] }
        }
    }

    static func configuration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        return configuration
    }

    @Test("a redirect is not followed, so the token isn't sent on")
    func redirectsAreRefused() async throws {
        StubProtocol.reset([
            "phone.local": .init(status: 307, headers: ["Location": "http://elsewhere.example/mcp"]),
            "elsewhere.example": .init(status: 200, body: Data("stolen".utf8)),
        ])
        let transport = URLSessionMCPTransport(endpoint: try #require(MCPEndpoint("http://phone.local:9000/mcp")),
                                               configuration: Self.configuration())
        let response = try await transport.post(Data("{}".utf8), headers: ["Authorization": "Bearer secret"])
        #expect(response.statusCode == 307)
        let hosts = StubProtocol.lock.withLock { StubProtocol.seen.map { $0.url?.host() ?? "" } }
        #expect(hosts == ["phone.local"], "nothing went to the redirect's target")
    }

    @Test("a reply past the limit is stopped, with or without a declared length")
    func repliesAreBounded() async throws {
        let big = Data(repeating: 0x41, count: 4_096)
        StubProtocol.reset([
            "declared.local": .init(headers: ["Content-Length": "\(big.count)"], body: big),
            "undeclared.local": .init(body: big),
        ])
        let session = GuardedSession(configuration: Self.configuration(), limit: 1_000)
        for host in ["declared.local", "undeclared.local"] {
            await #expect(throws: GuardedSession.TooLarge(limit: 1_000)) {
                _ = try await session.data(for: URLRequest(url: URL(string: "http://\(host)/")!))
            }
        }
    }

    @Test("an ordinary reply arrives whole")
    func ordinaryRepliesArriveWhole() async throws {
        let body = Data((0..<5_000).map { UInt8($0 % 251) })
        StubProtocol.reset(["phone.local": .init(body: body)])
        let session = GuardedSession(configuration: Self.configuration(), limit: 10_000)
        let (data, response) = try await session.data(for: URLRequest(url: URL(string: "http://phone.local/")!))
        #expect(data == body)
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
    }
}
