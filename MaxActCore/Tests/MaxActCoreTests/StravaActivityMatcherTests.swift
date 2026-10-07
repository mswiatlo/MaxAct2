import Foundation
import Testing

@testable import MaxActCore

@Suite struct StravaActivityMatcherTests {
    private let base = Date(timeIntervalSince1970: 1_791_396_000)   // 2026-10-07T18:00:00Z

    private func workout(_ id: String, at minutes: Double, for duration: Double, kind: ActivityKind = .cycling) -> Workout {
        let start = base.addingTimeInterval(minutes * 60)
        return Workout(id: id, kind: kind, start: start, end: start.addingTimeInterval(duration * 60),
                       duration: duration * 60)
    }

    private func activity(_ id: Int, at minutes: Double, for duration: Double, externalID: String? = nil)
        -> StravaActivitySummary {
        StravaActivitySummary(id: id, startDate: base.addingTimeInterval(minutes * 60),
                              elapsedTime: duration * 60, externalID: externalID)
    }

    @Test("the same ride recorded by the watch is found, despite a slightly different start")
    func sameEvent() {
        // The watch app started the clock 40 s before HealthKit's record did.
        let matches = StravaActivityMatcher.match(
            [workout("HK-1", at: 0, for: 60)], against: [activity(900, at: -0.67, for: 61)]
        )
        #expect(matches == ["HK-1": 900])
    }

    @Test("our own upload is recognised by its external id, wherever its times fall")
    func externalID() {
        let matches = StravaActivityMatcher.match(
            [workout("HK-1", at: 0, for: 60)], against: [activity(900, at: 300, for: 5, externalID: "HK-1")]
        )
        #expect(matches == ["HK-1": 900])
    }

    @Test("a short walk before a long ride is not the ride")
    func startAloneIsNotEnough() {
        // The ride starts six minutes after the walk did — inside the start tolerance — but only
        // once the walk has finished. They share no time at all, so start time alone would have
        // marked the walk as on Strava when it isn't.
        let walk = workout("WALK", at: 0, for: 5, kind: .walking)
        let ride = activity(900, at: 6, for: 120)
        #expect(StravaActivityMatcher.match([walk], against: [ride]).isEmpty)
    }

    @Test("starting more than ten minutes apart is a different workout")
    func outsideTolerance() {
        #expect(StravaActivityMatcher.match(
            [workout("HK-1", at: 0, for: 60)], against: [activity(900, at: 11, for: 60)]
        ).isEmpty)
    }

    @Test("one Strava activity can't mark two workouts")
    func oneToOne() {
        // Two HealthKit records of the same ride (watch and phone both recorded it) — only the
        // better-overlapping one is the Strava activity; the other remains a candidate to upload.
        let matches = StravaActivityMatcher.match(
            [workout("WATCH", at: 0, for: 60), workout("PHONE", at: 5, for: 30)],
            against: [activity(900, at: 0, for: 60)]
        )
        #expect(matches.count == 1)
        #expect(matches["WATCH"] == 900)
    }

    @Test("a certain match is never taken by a fuzzy one")
    func externalIDWinsTheActivity() {
        let matches = StravaActivityMatcher.match(
            [workout("OTHER", at: 0, for: 60), workout("OURS", at: 500, for: 60)],
            against: [activity(900, at: 0, for: 60, externalID: "OURS")]
        )
        #expect(matches == ["OURS": 900])
    }

    @Test("a busy day pairs each workout with its own activity")
    func severalInADay() {
        let workouts = [workout("AM", at: 0, for: 30), workout("NOON", at: 240, for: 45),
                        workout("PM", at: 600, for: 90)]
        let activities = [activity(1, at: 1, for: 30), activity(2, at: 239, for: 46),
                          activity(3, at: 602, for: 88), activity(4, at: 900, for: 20)]
        #expect(StravaActivityMatcher.match(workouts, against: activities) == ["AM": 1, "NOON": 2, "PM": 3])
    }

    @Test("nothing on Strava means nothing matched")
    func empty() {
        #expect(StravaActivityMatcher.match([workout("HK-1", at: 0, for: 60)], against: []).isEmpty)
    }
}

@Suite struct StravaActivityListingTests {
    private let clock = Date(timeIntervalSince1970: 1_791_367_620)

    private func page(_ ids: Range<Int>) -> StravaHTTPResponse {
        let items: [[String: Any]] = ids.map {
            ["id": $0, "name": "Ride \($0)", "sport_type": "Ride", "start_date": "2026-10-07T18:00:00Z",
             "elapsed_time": 3600, "distance": 20_000.0, "external_id": NSNull()]
        }
        return StravaHTTPResponse(status: 200, body: try! JSONSerialization.data(withJSONObject: items))
    }

    private func client(_ transport: ScriptedTransport) -> StravaClient {
        let tokens = StravaTokens(accessToken: "A", refreshToken: "R", expiresAt: clock.addingTimeInterval(3600))
        return StravaClient(transport: transport, secrets: MemorySecrets(tokens: tokens),
                            now: { [clock] in clock }, sleep: { _ in })
    }

    @Test("pages are followed until a short one, and no further")
    func paging() async throws {
        let transport = ScriptedTransport([page(0..<200), page(200..<400), page(400..<437)])
        let activities = try await client(transport).activities(
            in: DateInterval(start: clock.addingTimeInterval(-86_400 * 365 * 7), end: clock)
        )
        #expect(activities.count == 437)
        #expect(await transport.requests.count == 3, "a short page is the last; no empty fourth request")
    }

    @Test("the request asks for the interval, 200 at a time, and decodes Strava's dates")
    func requestShape() async throws {
        let transport = ScriptedTransport([page(0..<3)])
        let interval = DateInterval(start: Date(timeIntervalSince1970: 1_700_000_000), end: clock)
        let activities = try await client(transport).activities(in: interval)

        let query = Dictionary(uniqueKeysWithValues: (URLComponents(
            url: try #require(await transport.requests.first?.url), resolvingAgainstBaseURL: false
        )?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        #expect(query["after"] == "1700000000")
        #expect(query["per_page"] == "200")
        #expect(activities.first?.startDate == Date(timeIntervalSince1970: 1_791_396_000))
        #expect(activities.first?.elapsedTime == 3600)
    }

    @Test("listing spends the read bucket")
    func readBucket() async throws {
        let transport = ScriptedTransport([page(0..<1)])
        let strava = client(transport)
        _ = try await strava.activities(in: DateInterval(start: clock.addingTimeInterval(-3600), end: clock))
        #expect(await strava.rateLimit.read.shortTermUsed == 1)
    }
}

@Suite struct AlreadyOnStravaStoreTests {
    private func store() throws -> WorkoutStore {
        WorkoutStore(modelContainer: try WorkoutStore.container(inMemory: true))
    }

    private func ingested(_ id: String) -> IngestedWorkout {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        return IngestedWorkout(
            workout: Workout(id: id, kind: .cycling, start: start, end: start.addingTimeInterval(3600), duration: 3600),
            series: WorkoutSeries(workoutID: id)
        )
    }

    @Test("a match marks the workout as already on Strava, with a link to it")
    func marks() async throws {
        let store = try store()
        try await store.upsert([ingested("A")])
        #expect(try await store.markAlreadyOnStrava(["A": 900]) == 1)
        let item = try #require(try await store.item(id: "A"))
        #expect(item.stravaState == .duplicate)
        #expect(item.stravaActivityID == 900)
    }

    @Test("a workout MaxAct uploaded is never rewritten by a background check")
    func preservesOurUploads() async throws {
        let store = try store()
        try await store.upsert([ingested("A"), ingested("B")])
        try await store.setStravaState(.uploaded, activityID: 111, for: "A")
        try await store.setStravaState(.uploading, uploadID: 5, for: "B")

        #expect(try await store.markAlreadyOnStrava(["A": 900, "B": 901]) == 0)
        #expect(try await store.item(id: "A")?.stravaActivityID == 111)
        #expect(try await store.item(id: "B")?.stravaState == .uploading)
    }

    @Test("a failed upload that turns out to be there already is corrected")
    func correctsFailures() async throws {
        let store = try store()
        try await store.upsert([ingested("A")])
        try await store.setStravaState(.failed(reason: "timeout"), for: "A")
        #expect(try await store.markAlreadyOnStrava(["A": 900]) == 1)
        #expect(try await store.item(id: "A")?.stravaState == .duplicate)
    }
}
