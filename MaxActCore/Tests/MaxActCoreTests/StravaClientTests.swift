import Foundation
import Testing

@testable import MaxActCore

// MARK: - Fakes

/// Replays scripted responses in order and records every request, so a test can assert both what
/// was sent and how the client reacted.
actor ScriptedTransport: StravaTransport {
    private var script: [StravaHTTPResponse]
    private(set) var requests: [StravaHTTPRequest] = []

    init(_ script: [StravaHTTPResponse]) { self.script = script }

    func send(_ request: StravaHTTPRequest) async throws -> StravaHTTPResponse {
        requests.append(request)
        guard !script.isEmpty else { throw StravaError.invalidResponse("script exhausted") }
        return script.removeFirst()
    }

    func paths() -> [String] { requests.map { "\($0.method) \($0.url.path)" } }
}

actor MemorySecrets: StravaSecretStore {
    var storedCredentials: StravaCredentials?
    var storedTokens: StravaTokens?

    init(credentials: StravaCredentials? = StravaCredentials(clientID: "1234", clientSecret: "s3cret"),
         tokens: StravaTokens? = nil) {
        storedCredentials = credentials
        storedTokens = tokens
    }

    func credentials() async -> StravaCredentials? { storedCredentials }
    func tokens() async -> StravaTokens? { storedTokens }
    func save(tokens: StravaTokens?) async throws { storedTokens = tokens }
}

private let clock = Date(timeIntervalSince1970: 1_791_367_620)   // 2026-10-07T10:07:00Z

private func json(_ status: Int, _ object: Any, headers: [String: String] = [:]) -> StravaHTTPResponse {
    StravaHTTPResponse(status: status, headers: headers,
                       body: try! JSONSerialization.data(withJSONObject: object))
}

private func tokenResponse(access: String, refresh: String, athlete: Bool = true) -> StravaHTTPResponse {
    var body: [String: Any] = ["token_type": "Bearer", "access_token": access, "refresh_token": refresh,
                               "expires_at": clock.timeIntervalSince1970 + 21_600, "expires_in": 21_600]
    if athlete { body["athlete"] = ["firstname": "Max", "lastname": "S"] }
    return json(200, body)
}

private func upload(_ id: Int, status: String = "Your activity is still being processed.",
                    activity: Int? = nil, error: String? = nil) -> StravaHTTPResponse {
    var body: [String: Any] = ["id": id, "id_str": "\(id)", "external_id": "W", "status": status]
    body["activity_id"] = activity ?? NSNull()
    body["error"] = error ?? NSNull()
    return json(201, body)
}

private let freshTokens = StravaTokens(accessToken: "A1", refreshToken: "R1",
                                       expiresAt: clock.addingTimeInterval(3600), athleteName: "Max S")

private func client(_ transport: ScriptedTransport, _ secrets: MemorySecrets) -> StravaClient {
    StravaClient(transport: transport, secrets: secrets, now: { clock }, sleep: { _ in })
}

// MARK: - Client

@Suite struct StravaClientTests {
    @Test("the authorisation URL asks for the scopes uploading needs")
    func authorizationURL() throws {
        let url = StravaClient.authorizationURL(clientID: "1234", redirectURI: "maxact://localhost/strava",
                                                state: "xyz")
        let items = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        let query = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
        #expect(query["scope"] == "activity:write,activity:read_all")
        #expect(query["response_type"] == "code")
        #expect(query["redirect_uri"] == "maxact://localhost/strava")
        #expect(query["state"] == "xyz")
    }

    @Test("exchanging a code stores tokens and the athlete's name")
    func exchange() async throws {
        let transport = ScriptedTransport([tokenResponse(access: "A1", refresh: "R1")])
        let secrets = MemorySecrets()
        let tokens = try await client(transport, secrets).exchange(code: "abc")

        #expect(tokens.athleteName == "Max S")
        #expect(await secrets.storedTokens == tokens)
        let body = String(decoding: try #require(await transport.requests.first?.body), as: UTF8.self)
        #expect(body.contains("grant_type=authorization_code"))
        #expect(body.contains("client_secret=s3cret"))
        #expect(body.contains("code=abc"))
    }

    @Test("without tokens, nothing is sent")
    func notAuthorized() async throws {
        let transport = ScriptedTransport([])
        await #expect(throws: StravaError.notAuthorized) {
            _ = try await client(transport, MemorySecrets()).uploadStatus(id: 1)
        }
        #expect(await transport.requests.isEmpty)
    }

    @Test("a stale token is refreshed before the request, and the name survives the refresh")
    func proactiveRefresh() async throws {
        let stale = StravaTokens(accessToken: "OLD", refreshToken: "R0",
                                 expiresAt: clock.addingTimeInterval(60), athleteName: "Max S")
        let transport = ScriptedTransport([
            tokenResponse(access: "NEW", refresh: "R2", athlete: false),
            upload(9),
        ])
        let secrets = MemorySecrets(tokens: stale)
        _ = try await client(transport, secrets).uploadStatus(id: 9)

        let requests = await transport.requests
        #expect(requests.first?.url == StravaClient.tokenEndpoint)
        #expect(requests.last?.headers["Authorization"] == "Bearer NEW")
        #expect(await secrets.storedTokens?.refreshToken == "R2", "Strava rotates refresh tokens")
        #expect(await secrets.storedTokens?.athleteName == "Max S")
    }

    @Test("a 401 triggers one refresh and one retry")
    func reactiveRefresh() async throws {
        let transport = ScriptedTransport([
            json(401, ["message": "Authorization Error"]),
            tokenResponse(access: "A2", refresh: "R2"),
            upload(9),
        ])
        let response = try await client(transport, MemorySecrets(tokens: freshTokens)).uploadStatus(id: 9)
        #expect(response.id == 9)
        #expect(await transport.requests.last?.headers["Authorization"] == "Bearer A2")
    }

    @Test("a second 401 is reported as a rejected connection, not retried for ever")
    func persistentUnauthorized() async throws {
        let transport = ScriptedTransport([
            json(401, ["message": "Authorization Error"]),
            tokenResponse(access: "A2", refresh: "R2"),
            json(401, ["message": "Authorization Error", "errors": [["field": "access_token", "code": "invalid"]]]),
        ])
        await #expect(throws: StravaError.authorizationRejected("Authorization Error: access_token invalid")) {
            _ = try await client(transport, MemorySecrets(tokens: freshTokens)).uploadStatus(id: 9)
        }
    }

    @Test("a 429 reports when uploads can resume")
    func throttled() async throws {
        let transport = ScriptedTransport([
            json(429, ["message": "Rate Limit Exceeded"],
                 headers: ["X-RateLimit-Usage": "201,900", "X-RateLimit-Limit": "200,2000"]),
        ])
        let quarter = StravaRateLimit.nextQuarterHour(after: clock)
        await #expect(throws: StravaError.rateLimited(until: quarter)) {
            _ = try await client(transport, MemorySecrets(tokens: freshTokens)).uploadStatus(id: 9)
        }
    }

    @Test("an exhausted budget is reported up front rather than slept through")
    func longWaitThrows() async throws {
        let transport = ScriptedTransport([
            json(200, ["id": 1], headers: ["X-ReadRateLimit-Usage": "100,500", "X-ReadRateLimit-Limit": "100,1000",
                                            "X-RateLimit-Usage": "100,500", "X-RateLimit-Limit": "200,2000"]),
        ])
        let strava = client(transport, MemorySecrets(tokens: freshTokens))
        _ = try await strava.uploadStatus(id: 1)
        await #expect(throws: StravaError.rateLimited(until: StravaRateLimit.nextQuarterHour(after: clock))) {
            _ = try await strava.uploadStatus(id: 1)
        }
        #expect(await transport.requests.count == 1, "the second poll never left")
    }

    @Test("the upload carries the TCX, our id for dedupe, and the trainer flag")
    func uploadForm() async throws {
        let transport = ScriptedTransport([upload(77)])
        _ = try await client(transport, MemorySecrets(tokens: freshTokens)).upload(
            file: Data("<tcx/>".utf8), fileName: "W.tcx", name: "Evening Ride", description: nil,
            externalID: "HK-UUID", commute: false, trainer: true
        )
        let request = try #require(await transport.requests.first)
        let body = String(decoding: try #require(request.body), as: UTF8.self)
        #expect(request.method == "POST" && request.url.path == "/api/v3/uploads")
        #expect(request.headers["Content-Type"]?.hasPrefix("multipart/form-data; boundary=") == true)
        for (field, value) in [("data_type", "tcx"), ("external_id", "HK-UUID"), ("trainer", "1"),
                               ("commute", "0"), ("name", "Evening Ride")] {
            #expect(body.contains("name=\"\(field)\"\r\n\r\n\(value)\r\n"), "\(field) missing")
        }
        #expect(body.contains("filename=\"W.tcx\""))
        #expect(body.contains("<tcx/>"))
        #expect(!body.contains("name=\"description\""), "an empty description isn't sent")
    }

    @Test("polls spend the read bucket; uploads only the overall one")
    func bucketsSpent() async throws {
        let transport = ScriptedTransport([upload(1), upload(1)])
        let strava = client(transport, MemorySecrets(tokens: freshTokens))
        _ = try await strava.upload(file: Data(), fileName: "W.tcx", name: "x", description: nil,
                                    externalID: "W", commute: false, trainer: false)
        #expect(await strava.rateLimit.read.shortTermUsed == 0)
        _ = try await strava.uploadStatus(id: 1)
        #expect(await strava.rateLimit.read.shortTermUsed == 1)
        #expect(await strava.rateLimit.overall.shortTermUsed == 2)
    }

    @Test("Strava's error body becomes a readable reason")
    func errorMessage() {
        let response = json(400, ["message": "Bad Request",
                                  "errors": [["resource": "Upload", "field": "file", "code": "empty"]]])
        #expect(StravaClient.message(from: response) == "Bad Request: file empty")
    }
}

// MARK: - Upload outcomes

@Suite struct StravaUploadOutcomeTests {
    @Test("processing is not success")
    func processing() {
        #expect(StravaUploadResponse(id: 1, status: "Your activity is still being processed.").outcome == .processing)
    }

    @Test("an activity id means ready")
    func ready() {
        #expect(StravaUploadResponse(id: 1, activityID: 42).outcome == .ready(activityID: 42))
    }

    @Test("a duplicate is recognised in both of Strava's phrasings, ignoring digits in the file name")
    func duplicates() {
        let plain = StravaUploadResponse(id: 1, error: "2026-10-07.tcx duplicate of activity 15550001")
        let linked = StravaUploadResponse(
            id: 1, error: "W123.tcx duplicate of <a href='/activities/15550002' target='_blank'>Evening Ride</a>")
        #expect(plain.outcome == .duplicate(activityID: 15_550_001))
        #expect(linked.outcome == .duplicate(activityID: 15_550_002))
    }

    @Test("any other error is a failure with Strava's own words")
    func failure() {
        let response = StravaUploadResponse(id: 1, error: "Time information is missing from file.")
        #expect(response.outcome == .failed("Time information is missing from file."))
    }

    @Test("only runs and rides arrive with the right sport on their own")
    func sportCorrection() {
        #expect(!ActivityKind.running.stravaNeedsSportCorrection)
        #expect(!ActivityKind.cycling.stravaNeedsSportCorrection)
        #expect(ActivityKind.walking.stravaNeedsSportCorrection)
        #expect(ActivityKind.walking.stravaSportType == "Walk")
        #expect(ActivityKind.strengthTraining.stravaSportType == "WeightTraining")
    }
}

// MARK: - Uploader

@Suite struct StravaUploaderTests {
    private let start = Date(timeIntervalSince1970: 1_791_396_000)   // 2026-10-07T18:00:00Z

    private func workout(_ kind: ActivityKind, indoor: Bool = false) -> (Workout, WorkoutSeries) {
        let route = (0..<20).map {
            RoutePoint(coordinate: Coordinate(latitude: 49.25, longitude: -123.1 + Double($0) * 0.0001),
                       timestamp: start.addingTimeInterval(Double($0)), speedMetersPerSecond: 3,
                       horizontalAccuracyMeters: 8)
        }
        let workout = Workout(id: "HK-1", kind: kind, start: start, end: start.addingTimeInterval(20),
                              duration: 20, distanceMeters: 140, isIndoor: indoor, hasRoute: !indoor)
        return (workout, WorkoutSeries(workoutID: "HK-1", route: indoor ? [] : route))
    }

    private func uploader(_ transport: ScriptedTransport) -> StravaUploader {
        StravaUploader(client: client(transport, MemorySecrets(tokens: freshTokens)),
                       timeZone: TimeZone(identifier: "America/Vancouver")!, sleep: { _ in })
    }

    actor Recorder { var ids: [Int] = []; func add(_ id: Int) { ids.append(id) } }

    @Test("a ride is uploaded, polled to completion, and not corrected")
    func ride() async throws {
        let transport = ScriptedTransport([upload(5), upload(5), upload(5, activity: 900)])
        let (workout, series) = workout(.cycling)
        let recorder = Recorder()
        let result = try await uploader(transport).send(workout, series: series) { await recorder.add($0) }

        #expect(result == UploadResult(state: .uploaded, activityID: 900, uploadID: 5, warning: nil))
        #expect(await recorder.ids == [5], "the id is handed back before polling, to be persisted")
        #expect(await transport.paths() == ["POST /api/v3/uploads", "GET /api/v3/uploads/5",
                                            "GET /api/v3/uploads/5"])
    }

    @Test("a walk gets its sport corrected, because TCX can't say 'walk'")
    func walkCorrected() async throws {
        let transport = ScriptedTransport([upload(5, activity: 900), json(200, ["id": 900])])
        let (workout, series) = workout(.walking)
        let result = try await uploader(transport).send(workout, series: series) { _ in }

        #expect(result.state == .uploaded)
        let put = try #require(await transport.requests.last)
        #expect(put.method == "PUT" && put.url.path == "/api/v3/activities/900")
        #expect(String(decoding: try #require(put.body), as: UTF8.self).contains("\"Walk\""))
    }

    @Test("a failed correction still counts as uploaded, with the problem reported")
    func correctionFailure() async throws {
        let transport = ScriptedTransport([upload(5, activity: 900), json(500, ["message": "Server Error"])])
        let (workout, series) = workout(.hiking)
        let result = try await uploader(transport).send(workout, series: series) { _ in }
        #expect(result.state == .uploaded)
        #expect(result.warning?.contains("Hike") == true)
    }

    @Test("a duplicate is recorded as already there, not as a failure")
    func duplicate() async throws {
        let transport = ScriptedTransport([upload(5, error: "HK-1.tcx duplicate of activity 4321")])
        let (workout, series) = workout(.running)
        let result = try await uploader(transport).send(workout, series: series) { _ in }
        #expect(result.state == .duplicate)
        #expect(result.activityID == 4321)
    }

    @Test("an upload still processing after the schedule stays in flight, to be resumed")
    func givesUpForNow() async throws {
        let polls = StravaUploader.pollSchedule.count
        let transport = ScriptedTransport(Array(repeating: upload(5), count: polls + 1))
        let (workout, series) = workout(.cycling)
        let result = try await uploader(transport).send(workout, series: series) { _ in }
        #expect(result.state == .uploading)
        #expect(result.uploadID == 5)
    }

    @Test("resuming polls the saved id instead of uploading again")
    func resume() async throws {
        let transport = ScriptedTransport([upload(5, activity: 900)])
        let (workout, _) = workout(.cycling)
        let result = try await uploader(transport).resume(uploadID: 5, workout: workout)
        #expect(result.state == .uploaded)
        #expect(await transport.paths() == ["GET /api/v3/uploads/5"])
    }

    @Test("an indoor session is uploaded with the trainer flag and no route")
    func indoor() async throws {
        let transport = ScriptedTransport([upload(5, activity: 900)])
        let (workout, series) = workout(.indoorCycling, indoor: true)
        _ = try await uploader(transport).send(workout, series: series) { _ in }
        let body = String(decoding: try #require(await transport.requests.first?.body), as: UTF8.self)
        #expect(body.contains("name=\"trainer\"\r\n\r\n1\r\n"))
        #expect(!body.contains("<Position>"))
    }

    @Test("activities are named the way Strava names them, in local time")
    func names() {
        let vancouver = TimeZone(identifier: "America/Vancouver")!
        // 18:00Z is 11:00 in Vancouver (PDT).
        #expect(StravaUploader.activityName(for: workout(.walking).0, in: vancouver) == "Lunch Walk")
        #expect(StravaUploader.activityName(for: workout(.indoorCycling).0, in: TimeZone(identifier: "UTC")!)
                == "Evening Indoor Ride")
    }
}
