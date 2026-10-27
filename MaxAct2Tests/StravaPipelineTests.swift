import Foundation
import MaxActCore
import Testing

@testable import MaxAct2

/// Issue 43: the app's Strava upload path, against a pretend Strava.
@MainActor @Suite struct StravaPipelineTests {
    /// Answers by endpoint: no activities on Strava yet, an upload accepted as id 9, and a poll
    /// that finds it ready as activity 77. `acceptDelay` holds the upload request, uncancellably,
    /// like one already on its way.
    actor PretendStrava: StravaTransport {
        let acceptDelay: Duration
        private(set) var uploads = 0
        private(set) var polls = 0

        init(acceptDelay: Duration = .zero) { self.acceptDelay = acceptDelay }

        func send(_ request: StravaHTTPRequest) async throws -> StravaHTTPResponse {
            let path = request.url.path
            switch request.method {
            case "GET" where path.hasSuffix("/athlete/activities"):
                return Self.json(200, [Any]())
            case "POST" where path.hasSuffix("/uploads"):
                uploads += 1
                if acceptDelay > .zero { await Task.detached { [acceptDelay] in try? await Task.sleep(for: acceptDelay) }.value }
                return Self.json(201, Self.upload(activity: nil))
            case "GET" where path.hasSuffix("/uploads/9"):
                polls += 1
                return Self.json(200, Self.upload(activity: 77))
            case "PUT":
                return Self.json(200, ["id": 77])
            default:
                return Self.json(404, ["message": "Record Not Found"])
            }
        }

        static func upload(activity: Int?) -> [String: Any] {
            ["id": 9, "id_str": "9", "external_id": "W", "error": NSNull(), "activity_id": activity ?? NSNull(),
             "status": activity == nil ? "Your activity is still being processed." : "Your activity is ready."]
        }

        static func json(_ status: Int, _ object: Any) -> StravaHTTPResponse {
            StravaHTTPResponse(status: status, body: try! JSONSerialization.data(withJSONObject: object))
        }
    }

    private func model(strava: PretendStrava) async throws -> AppModel {
        let suite = "StravaPipelineTests"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let secrets = InMemorySecretStore()
        try await secrets.save(credentials: StravaCredentials(clientID: "1", clientSecret: "s"))
        try await secrets.save(tokens: StravaTokens(accessToken: "A", refreshToken: "R",
                                                    expiresAt: .now.addingTimeInterval(3600), athleteName: "Test"))
        let model = AppModel.inMemoryFallback(settings: AppSettings(defaults: defaults, tokenStore: InMemoryHAETokenStore()), seedCount: 40,
                                              resolvesPlaces: false, stravaSecrets: secrets, stravaTransport: strava)
        await model.load()
        try #require(model.isStravaConnected)
        return model
    }

    /// A ride with detail: rides need no sport correction afterwards.
    private func ride(_ model: AppModel) throws -> WorkoutListItem {
        try #require(model.items.first { $0.workout.kind == .cycling && $0.hasDetail && $0.id != "SEED-0" })
    }

    @Test func anUploadEndsUploadedAndLinked() async throws {
        let strava = PretendStrava()
        let model = try await model(strava: strava)
        let ride = try ride(model)
        model.startStravaUpload(for: [ride])
        await model.waitForJob()
        let after = try #require(model.items.first { $0.id == ride.id })
        #expect(after.stravaState == .uploaded)
        #expect(after.stravaActivityID == 77)
        #expect(model.syncStatus == .finished(.uploadingToStrava, found: 1), "\(model.syncStatus)")
    }

    /// Issue 38's fix, untested until now: stopping mid-upload isn't the workout's failure.
    @Test func stoppingMidUploadLeavesItResumable() async throws {
        let strava = PretendStrava(acceptDelay: .milliseconds(500))
        let model = try await model(strava: strava)
        let ride = try ride(model)
        model.startStravaUpload(for: [ride])
        for _ in 0..<200 where await strava.uploads == 0 { try await Task.sleep(for: .milliseconds(10)) }
        model.cancelSync()
        await model.waitForJob()
        let after = try #require(model.items.first { $0.id == ride.id })
        if case .failed = after.stravaState { Issue.record("marked failed: \(after.stravaState)") }
        #expect(after.stravaState == .uploading, "accepted, so resumed later rather than sent again")
    }

    /// An upload a previous run saw accepted is followed by its id, not sent again.
    @Test func anUploadInFlightIsResumedNotRepeated() async throws {
        let strava = PretendStrava()
        let model = try await model(strava: strava)
        let ride = try ride(model)
        try await model.store.setStravaState(.uploading, uploadID: 9, for: ride.id)
        await model.refreshItems()
        model.startStravaUpload(for: [try #require(model.items.first { $0.id == ride.id })])
        await model.waitForJob()
        #expect(await strava.uploads == 0)
        #expect(await strava.polls > 0)
        #expect(model.items.first { $0.id == ride.id }?.stravaState == .uploaded)
    }
}
