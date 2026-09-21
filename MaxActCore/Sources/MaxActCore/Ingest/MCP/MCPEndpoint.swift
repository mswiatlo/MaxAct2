import Foundation

/// Where Health Auto Export's MCP server lives, parsed from whatever the user typed.
///
/// The field in the UI asks for "the address from the Server screen", and that screen shows
/// something like `http://10.0.0.158:9000/mcp`. People reasonably paste the whole thing, or type
/// just the IP, or `host:port`. All three now work.
///
/// This exists because the first version built a `URLComponents` with the raw text as `host` and
/// force-unwrapped `.url`. A pasted full URL makes that `nil`, so the app hard-crashed with
/// "Unexpectedly found nil while unwrapping an Optional value" the moment Start Sync was pressed.
public struct MCPEndpoint: Sendable, Equatable, CustomStringConvertible {
    public static let defaultPort = 9000
    public static let defaultPath = "/mcp"

    public let url: URL

    public var description: String { url.absoluteString }

    /// Returns `nil` for input that can't be made into an endpoint, so the caller can report the
    /// problem. Never traps.
    public init?(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // A scheme means we can let URLComponents do the parsing; otherwise give it one, since
        // "10.0.0.158:9000" alone parses as scheme "10.0.0.158" with path "9000".
        let hasScheme = trimmed.lowercased().hasPrefix("http://")
            || trimmed.lowercased().hasPrefix("https://")
        guard var components = URLComponents(string: hasScheme ? trimmed : "http://\(trimmed)") else {
            return nil
        }

        guard let host = components.host, !host.isEmpty, !host.contains(" ") else { return nil }
        components.scheme = components.scheme?.lowercased() ?? "http"
        if components.port == nil { components.port = Self.defaultPort }

        let path = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        components.path = path.isEmpty ? Self.defaultPath : "/\(path)"

        // Credentials and queries would be meaningless here and only confuse diagnostics.
        components.user = nil
        components.password = nil
        components.query = nil
        components.fragment = nil

        guard let url = components.url else { return nil }
        self.url = url
    }

    public init(host: String, port: Int = MCPEndpoint.defaultPort) {
        var components = URLComponents()
        components.scheme = "http"
        components.host = host
        components.port = port
        components.path = Self.defaultPath
        // Safe: a bare host with no scheme or path characters always forms a URL. The failable
        // initialiser above is the one to use for user input.
        url = components.url ?? URL(string: "http://\(host):\(port)\(Self.defaultPath)")!
    }
}
