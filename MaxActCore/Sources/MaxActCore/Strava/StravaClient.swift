import Foundation

public struct StravaHTTPRequest: Sendable, Equatable {
    public var method: String
    public var url: URL
    public var headers: [String: String]
    public var body: Data?
}

public struct StravaHTTPResponse: Sendable {
    public let status: Int
    public let headers: [String: String]
    public let body: Data

    public init(status: Int, headers: [String: String] = [:], body: Data = Data()) {
        self.status = status
        self.headers = headers
        self.body = body
    }
}

/// The HTTP boundary, abstracted so the client is testable without Strava — or without spending
/// any of a real account's rate limit.
public protocol StravaTransport: Sendable {
    func send(_ request: StravaHTTPRequest) async throws -> StravaHTTPResponse
}

public struct URLSessionStravaTransport: StravaTransport {
    private let session: URLSession

    public init() {
        let configuration = URLSessionConfiguration.ephemeral
        // An upload of a long ride is a few hundred kilobytes; generous, but not unbounded.
        configuration.timeoutIntervalForRequest = 120
        session = URLSession(configuration: configuration)
    }

    public func send(_ request: StravaHTTPRequest) async throws -> StravaHTTPResponse {
        var urlRequest = URLRequest(url: request.url)
        urlRequest.httpMethod = request.method
        urlRequest.httpBody = request.body
        for (name, value) in request.headers { urlRequest.setValue(value, forHTTPHeaderField: name) }
        let (data, response) = try await session.data(for: urlRequest)
        guard let http = response as? HTTPURLResponse else {
            throw StravaError.invalidResponse("not an HTTP response")
        }
        let headers = http.allHeaderFields.reduce(into: [String: String]()) { result, pair in
            if let name = pair.key as? String, let value = pair.value as? String { result[name] = value }
        }
        return StravaHTTPResponse(status: http.statusCode, headers: headers, body: data)
    }
}

/// Talks to Strava API v3: OAuth, uploads, upload status and activity updates.
///
/// An actor because two things must be serialised: the token (two concurrent refreshes would each
/// invalidate the other's refresh token) and the rate-limit budget, which every request spends.
public actor StravaClient {
    public static let apiBase = URL(string: "https://www.strava.com/api/v3")!
    static let authorizeEndpoint = URL(string: "https://www.strava.com/oauth/authorize")!
    static let tokenEndpoint = URL(string: "https://www.strava.com/oauth/token")!

    /// `activity:write` to upload; `activity:read_all` to read back status of private activities.
    public static let scope = "activity:write,activity:read_all"

    /// Waits shorter than this are slept through; longer ones are thrown as
    /// ``StravaError/rateLimited(until:)`` so the caller can say so rather than hang for 15 minutes.
    static let longestQuietWait: TimeInterval = 60

    private let transport: any StravaTransport
    private let secrets: any StravaSecretStore
    private let now: @Sendable () -> Date
    private let sleep: @Sendable (TimeInterval) async throws -> Void

    public private(set) var rateLimit = StravaRateLimit()

    public init(
        transport: any StravaTransport = URLSessionStravaTransport(),
        secrets: any StravaSecretStore,
        now: @escaping @Sendable () -> Date = { Date() },
        sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { try await Task.sleep(for: .seconds($0)) }
    ) {
        self.transport = transport
        self.secrets = secrets
        self.now = now
        self.sleep = sleep
    }

    // MARK: - Authorization

    /// The page the user approves access on. `approval_prompt=auto` skips the prompt for an
    /// already-approved app, which makes reconnecting a single click.
    public nonisolated static func authorizationURL(clientID: String, redirectURI: String, state: String) -> URL {
        var components = URLComponents(url: authorizeEndpoint, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "approval_prompt", value: "auto"),
            URLQueryItem(name: "scope", value: scope),
            URLQueryItem(name: "state", value: state),
        ]
        return components.url!
    }

    /// Trades the code from the callback for tokens, and stores them.
    @discardableResult
    public func exchange(code: String) async throws -> StravaTokens {
        guard let credentials = await secrets.credentials(), credentials.isComplete else {
            throw StravaError.notConfigured
        }
        let tokens = try await requestTokens([
            "client_id": credentials.clientID,
            "client_secret": credentials.clientSecret,
            "code": code,
            "grant_type": "authorization_code",
        ], previous: nil)
        try await secrets.save(tokens: tokens)
        return tokens
    }

    public func disconnect() async throws {
        try await secrets.save(tokens: nil)
    }

    // MARK: - API

    public func upload(
        file: Data, fileName: String, name: String, description: String?,
        externalID: String, commute: Bool, trainer: Bool
    ) async throws -> StravaUploadResponse {
        var fields: [(String, String)] = [
            ("data_type", "tcx"),
            ("name", name),
            ("external_id", externalID),
            ("commute", commute ? "1" : "0"),
            ("trainer", trainer ? "1" : "0"),
        ]
        if let description, !description.isEmpty { fields.append(("description", description)) }
        let multipart = Multipart(fields: fields, file: file, fileName: fileName)
        let response = try await send(
            method: "POST", path: "uploads", kind: .write,
            headers: ["Content-Type": multipart.contentType], body: multipart.body
        )
        return try decode(StravaUploadResponse.self, from: response)
    }

    public func uploadStatus(id: Int) async throws -> StravaUploadResponse {
        let response = try await send(method: "GET", path: "uploads/\(id)", kind: .read)
        return try decode(StravaUploadResponse.self, from: response)
    }

    /// Changes an existing activity. Only the fields set are sent, and an empty update sends
    /// nothing — every `PUT` is a write against the 200 / 15 min budget.
    public func updateActivity(id: Int, _ update: StravaActivityUpdate) async throws {
        guard !update.isEmpty else { return }
        let body = try JSONSerialization.data(withJSONObject: update.json)
        _ = try await send(
            method: "PUT", path: "activities/\(id)", kind: .write,
            headers: ["Content-Type": "application/json"], body: body
        )
    }

    /// Sets the sport, which the upload itself can't: the TCX format only knows three.
    public func updateActivity(id: Int, sportType: String) async throws {
        try await updateActivity(id: id, StravaActivityUpdate(sportType: sportType))
    }

    /// One page of the athlete's activities. `after`/`before` are epoch seconds per the spec.
    func activitiesPage(after: Date, before: Date, page: Int, perPage: Int) async throws -> [StravaActivitySummary] {
        let response = try await send(
            method: "GET", path: "athlete/activities", kind: .read,
            query: [
                URLQueryItem(name: "after", value: String(Int(after.timeIntervalSince1970))),
                URLQueryItem(name: "before", value: String(Int(before.timeIntervalSince1970))),
                URLQueryItem(name: "page", value: String(page)),
                URLQueryItem(name: "per_page", value: String(perPage)),
            ]
        )
        return try decode([StravaActivitySummary].self, from: response)
    }

    // MARK: - Plumbing

    /// One authorised request: waits for rate-limit room, refreshes a stale token first, and
    /// retries exactly once with a fresh token on a 401.
    private func send(
        method: String, path: String, kind: StravaRateLimit.Kind,
        query: [URLQueryItem] = [], headers: [String: String] = [:], body: Data? = nil
    ) async throws -> StravaHTTPResponse {
        var tokens = try await validTokens()
        for attempt in 0..<2 {
            try await waitForRoom(kind)
            var url = Self.apiBase.appending(path: path)
            if !query.isEmpty { url.append(queryItems: query) }
            var request = StravaHTTPRequest(method: method, url: url, headers: headers, body: body)
            request.headers["Authorization"] = "Bearer \(tokens.accessToken)"

            rateLimit.spend(kind, at: now())
            let response = try await transport.send(request)

            switch response.status {
            case 429:
                rateLimit.recordThrottled(headers: response.headers, at: now())
                throw StravaError.rateLimited(until: rateLimit.blockedUntil ?? now())
            case 401 where attempt == 0:
                // Revoked or expired early. One refresh, then give up honestly.
                rateLimit.record(headers: response.headers, at: now())
                tokens = try await refresh(tokens)
                continue
            case 200..<300:
                rateLimit.record(headers: response.headers, at: now())
                return response
            default:
                rateLimit.record(headers: response.headers, at: now())
                if response.status == 401 {
                    throw StravaError.authorizationRejected(Self.message(from: response))
                }
                throw StravaError.http(status: response.status, message: Self.message(from: response))
            }
        }
        throw StravaError.authorizationRejected("token refused after refresh")
    }

    private func waitForRoom(_ kind: StravaRateLimit.Kind) async throws {
        let current = now()
        let start = rateLimit.earliestStart(for: kind, at: current)
        let wait = start.timeIntervalSince(current)
        guard wait > 0 else { return }
        if wait > Self.longestQuietWait { throw StravaError.rateLimited(until: start) }
        try await sleep(wait)
    }

    private func validTokens() async throws -> StravaTokens {
        guard let tokens = await secrets.tokens() else { throw StravaError.notAuthorized }
        return tokens.isFresh(at: now()) ? tokens : try await refresh(tokens)
    }

    private func refresh(_ tokens: StravaTokens) async throws -> StravaTokens {
        guard let credentials = await secrets.credentials(), credentials.isComplete else {
            throw StravaError.notConfigured
        }
        let refreshed = try await requestTokens([
            "client_id": credentials.clientID,
            "client_secret": credentials.clientSecret,
            "refresh_token": tokens.refreshToken,
            "grant_type": "refresh_token",
        ], previous: tokens)
        try await secrets.save(tokens: refreshed)
        return refreshed
    }

    /// OAuth token requests are the one kind that doesn't count against the rate limit.
    private func requestTokens(_ form: [String: String], previous: StravaTokens?) async throws -> StravaTokens {
        let body = form.sorted { $0.key < $1.key }
            .map { "\($0.key)=\(Self.formEncode($0.value))" }
            .joined(separator: "&")
        let response = try await transport.send(StravaHTTPRequest(
            method: "POST", url: Self.tokenEndpoint,
            headers: ["Content-Type": "application/x-www-form-urlencoded"], body: Data(body.utf8)
        ))
        guard (200..<300).contains(response.status) else {
            // A bad refresh token means the user has to reconnect; say that, not "HTTP 400".
            throw StravaError.authorizationRejected(Self.message(from: response))
        }
        struct TokenResponse: Decodable {
            struct Athlete: Decodable { let firstname: String?; let lastname: String? }
            let access_token: String
            let refresh_token: String
            let expires_at: TimeInterval
            let athlete: Athlete?
        }
        let decoded = try decode(TokenResponse.self, from: response)
        let name = decoded.athlete.map { [$0.firstname, $0.lastname].compactMap { $0 }.joined(separator: " ") }
        return StravaTokens(
            accessToken: decoded.access_token,
            refreshToken: decoded.refresh_token,
            expiresAt: Date(timeIntervalSince1970: decoded.expires_at),
            // A refresh response carries no athlete, so keep the name we already had.
            athleteName: name ?? previous?.athleteName
        )
    }

    private func decode<T: Decodable>(_ type: T.Type, from response: StravaHTTPResponse) throws -> T {
        do {
            // Strava's timestamps are ISO 8601 strings ("2026-10-07T18:00:00Z").
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode(type, from: response.body)
        } catch {
            throw StravaError.invalidResponse("\(T.self): \(error)")
        }
    }

    /// Strava errors are `{"message": "...", "errors": [{"resource", "field", "code"}]}`.
    static func message(from response: StravaHTTPResponse) -> String {
        struct Body: Decodable {
            struct Detail: Decodable { let field: String?; let code: String? }
            let message: String?
            let errors: [Detail]?
        }
        guard let body = try? JSONDecoder().decode(Body.self, from: response.body) else {
            return String(decoding: response.body.prefix(200), as: UTF8.self)
        }
        let detail = body.errors?.first.map { [$0.field, $0.code].compactMap { $0 }.joined(separator: " ") }
        return [body.message, detail].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ": ")
    }

    static func formEncode(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }
}

/// `multipart/form-data`, built by hand because `URLSession` has no form API.
struct Multipart {
    let boundary: String
    let body: Data

    var contentType: String { "multipart/form-data; boundary=\(boundary)" }

    init(fields: [(String, String)], file: Data, fileName: String,
         boundary: String = "MaxAct-\(UUID().uuidString)") {
        self.boundary = boundary
        var body = Data()
        func line(_ text: String) { body.append(Data((text + "\r\n").utf8)) }
        for (name, value) in fields {
            line("--\(boundary)")
            line("Content-Disposition: form-data; name=\"\(name)\"")
            line("")
            line(value)
        }
        line("--\(boundary)")
        line("Content-Disposition: form-data; name=\"file\"; filename=\"\(fileName)\"")
        line("Content-Type: application/vnd.garmin.tcx+xml")
        line("")
        body.append(file)
        line("")
        line("--\(boundary)--")
        self.body = body
    }
}
