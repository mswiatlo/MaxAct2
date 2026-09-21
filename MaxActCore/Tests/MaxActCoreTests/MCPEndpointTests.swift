import Foundation
import Testing

@testable import MaxActCore

/// The field asks for "the address", and Health Auto Export's Server screen displays a full URL,
/// so people paste all sorts of things. Every one of these used to either work or hard-crash the
/// app on `components.url!`.
@Suite struct MCPEndpointTests {

    @Test("all the forms someone might reasonably type resolve to the same endpoint", arguments: [
        "10.0.0.158",
        "10.0.0.158:9000",
        "http://10.0.0.158:9000/mcp",
        "http://10.0.0.158:9000/mcp/",
        "http://10.0.0.158/mcp",
        "http://10.0.0.158:9000",
        "  10.0.0.158  ",
        "HTTP://10.0.0.158:9000/MCP",
    ])
    func equivalentForms(input: String) throws {
        let endpoint = try #require(MCPEndpoint(input), "should parse: \(input)")
        #expect(endpoint.url.host() == "10.0.0.158")
        #expect(endpoint.url.port == 9000)
        #expect(endpoint.url.path().lowercased() == "/mcp")
    }

    @Test("the full URL a user would paste is exactly what the bare IP resolves to")
    func pastedURLMatchesBareIP() throws {
        let typed = try #require(MCPEndpoint("10.0.0.158"))
        let pasted = try #require(MCPEndpoint("http://10.0.0.158:9000/mcp"))
        #expect(typed == pasted)
        #expect(typed.description == "http://10.0.0.158:9000/mcp")
    }

    @Test("a hostname works as well as an IP")
    func hostnames() throws {
        let endpoint = try #require(MCPEndpoint("maxs-iphone.local"))
        #expect(endpoint.description == "http://maxs-iphone.local:9000/mcp")
    }

    @Test("an explicit port is honoured rather than overridden")
    func nonDefaultPort() throws {
        #expect(try #require(MCPEndpoint("10.0.0.158:8080")).url.port == 8080)
    }

    @Test("https is preserved, since the server can be configured for it")
    func httpsPreserved() throws {
        let endpoint = try #require(MCPEndpoint("https://10.0.0.158:9000/mcp"))
        #expect(endpoint.url.scheme == "https")
    }

    @Test("unusable input returns nil rather than trapping", arguments: [
        "", "   ", "http://", "not a host", "://nope",
    ])
    func rejectsGarbage(input: String) {
        #expect(MCPEndpoint(input) == nil, "should not parse: \(input)")
    }

    /// The exact regression: a pasted full URL used as `URLComponents.host` yields a nil `.url`,
    /// and the old code force-unwrapped it, crashing as soon as Start Sync was pressed.
    @Test("a pasted full URL does not crash the way it used to")
    func pastedURLDoesNotCrash() throws {
        var components = URLComponents()
        components.scheme = "http"
        components.host = "http://10.0.0.158:9000/mcp"
        components.port = 9000
        components.path = "/mcp"
        #expect(components.url == nil, "this is what the old code force-unwrapped")

        #expect(MCPEndpoint("http://10.0.0.158:9000/mcp") != nil, "the parser handles it")
    }
}
