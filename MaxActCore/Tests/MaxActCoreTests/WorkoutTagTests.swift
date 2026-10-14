import Foundation
import Testing

@testable import MaxActCore

@Suite struct WorkoutTagTests {
    @Test("typed names are tidied, and match existing tags regardless of case")
    func normalization() {
        #expect(WorkoutTag.normalized("  with   kid ") == "with kid")
        #expect(WorkoutTag.normalized("commute") == "Commute", "must not create a second Commute")
        #expect(WorkoutTag.normalized("with kid", existing: ["With Kid"]) == "With Kid")
        #expect(WorkoutTag.normalized("   ") == nil)
    }

    @Test("Strava's flags replace only the Strava-backed tags")
    func applyingFlags() {
        let tags = ["With Kid", "Commute"]
        #expect(WorkoutTag.applying(commute: false, trainer: true, to: tags) == ["Trainer", "With Kid"])
        #expect(WorkoutTag.applying(commute: true, trainer: false, to: tags) == nil, "already matches")
    }

    @Test("Race follows Strava where Strava can say, and is left alone where it can't")
    func applyingRace() {
        #expect(WorkoutTag.applying(commute: false, trainer: false, race: true, to: ["With Kid"]) == ["Race", "With Kid"])
        #expect(WorkoutTag.applying(commute: false, trainer: false, race: false, to: ["Race"]) == [])
        // A walk: Strava has no workout type, so a Mac-only Race tag stays.
        #expect(WorkoutTag.applying(commute: false, trainer: false, race: nil, to: ["Race"]) == nil)
    }

    @Test("what to send as workout_type: set a race, clear only a race, leave other types alone")
    func raceDecision() {
        #expect(StravaRace.value(toSend: true, for: .running, current: nil) == 1)
        #expect(StravaRace.value(toSend: true, for: .running, current: 0) == 1)
        #expect(StravaRace.value(toSend: true, for: .running, current: 1) == nil, "already a race")
        #expect(StravaRace.value(toSend: true, for: .cycling, current: 10) == 11)
        #expect(StravaRace.value(toSend: false, for: .running, current: 1) == 0, "clearing a race")
        #expect(StravaRace.value(toSend: false, for: .cycling, current: 11) == 10)
        #expect(StravaRace.value(toSend: false, for: .running, current: 2) == nil, "a Long Run stays a Long Run")
        #expect(StravaRace.value(toSend: false, for: .running, current: nil) == nil)
        #expect(StravaRace.value(toSend: true, for: .walking, current: nil) == nil, "walks have no workout type")
    }

    @Test("Strava-backed tags sort first, the rest alphabetically")
    func ordering() {
        #expect(WorkoutTag.sorted(["zebra", "Race", "Trainer", "apple", "Commute"]) == ["Commute", "Trainer", "Race", "apple", "zebra"])
    }

    @Test("an update sends only the fields that are set, under Strava's names")
    func updateJSON() {
        let update = StravaActivityUpdate(sportType: "Walk", muted: true)
        #expect(update.json["sport_type"] as? String == "Walk")
        #expect(update.json["hide_from_home"] as? Bool == true)
        #expect(update.json["commute"] == nil)
        #expect(update.json["workout_type"] == nil)
        #expect(StravaActivityUpdate(workoutType: 1).json["workout_type"] as? Int == 1)
        #expect(StravaActivityUpdate().isEmpty)
        #expect(!StravaActivityUpdate(workoutType: 0).isEmpty)
    }
}

@Suite struct TagStoreTests {
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

    @Test("tags apply to a whole selection, and survive a re-sync")
    func batchAndResync() async throws {
        let store = try store()
        try await store.upsert([ingested("A"), ingested("B")])
        try await store.addTag("With Kid", to: ["A", "B"])
        try await store.upsert([ingested("A"), ingested("B")])   // a later sync
        #expect(try await store.item(id: "A")?.tags == ["With Kid"])
        #expect(try await store.item(id: "B")?.tags == ["With Kid"])

        try await store.removeTag("With Kid", from: ["B"])
        #expect(try await store.item(id: "B")?.tags == [])
    }

    @Test("Commute, Trainer and Race are always offered, even before any workout has them")
    func builtInsOffered() async throws {
        let store = try store()
        try await store.upsert([ingested("A")])
        try await store.addTag("With Kid", to: ["A"])
        #expect(try await store.allTagNames() == ["Commute", "Trainer", "Race", "With Kid"])
    }

    @Test("editing a Strava-backed tag on a synced workout queues a push; a local tag doesn't")
    func pendingPush() async throws {
        let store = try store()
        try await store.upsert([ingested("SYNCED"), ingested("LOCAL")])
        try await store.setStravaState(.uploaded, activityID: 900, for: "SYNCED")

        #expect(try await store.addTag("With Kid", to: ["SYNCED"]).isEmpty, "local-only tag")
        #expect(try await store.addTag("Commute", to: ["SYNCED", "LOCAL"]) == ["SYNCED"],
                "only the synced workout has anything to push")

        let pending = try await store.pendingStravaFlags()
        #expect(pending.count == 1)
        #expect(pending.first?.activityID == 900)
        // `race: false`, not unknown: a pushed workout without the tag may need a race cleared.
        #expect(pending.first?.flags == StravaFlags(commute: true, trainer: false, race: false))
        #expect(pending.first?.kind == .cycling)
    }

    @Test("Strava's flags are mirrored onto synced workouts")
    func importFlags() async throws {
        let store = try store()
        try await store.upsert([ingested("A")])
        try await store.setStravaState(.duplicate, activityID: 900, for: "A")
        try await store.addTag("With Kid", to: ["A"])

        #expect(try await store.applyStravaFlags([900: StravaFlags(commute: true, trainer: false)]) == 1)
        #expect(try await store.item(id: "A")?.tags == ["Commute", "With Kid"], "local tags untouched")
    }

    @Test("a pending local edit is never overwritten by Strava's stale value")
    func pendingWins() async throws {
        let store = try store()
        try await store.upsert([ingested("A")])
        try await store.setStravaState(.uploaded, activityID: 900, for: "A")
        try await store.addTag("Commute", to: ["A"])   // not yet pushed

        // Strava still says not a commute — because our change hasn't reached it yet.
        #expect(try await store.applyStravaFlags([900: StravaFlags(commute: false, trainer: false)]) == 0)
        #expect(try await store.item(id: "A")?.tags == ["Commute"])

        try await store.clearStravaFlagsPending("A")
        #expect(try await store.pendingStravaFlags().isEmpty)
    }
}

@Suite struct UploadOptionsTests {
    private let start = Date(timeIntervalSince1970: 1_791_396_000)
    private let clock = Date(timeIntervalSince1970: 1_791_367_620)

    private func workout(_ kind: ActivityKind) -> (Workout, WorkoutSeries) {
        let route = (0..<10).map {
            RoutePoint(coordinate: Coordinate(latitude: 49.25, longitude: -123.1 + Double($0) * 0.0001),
                       timestamp: start.addingTimeInterval(Double($0)), speedMetersPerSecond: 3,
                       horizontalAccuracyMeters: 8)
        }
        return (Workout(id: "HK-1", kind: kind, start: start, end: start.addingTimeInterval(10),
                        duration: 10, distanceMeters: 30, hasRoute: true),
                WorkoutSeries(workoutID: "HK-1", route: route))
    }

    private func uploader(_ transport: ScriptedTransport) -> StravaUploader {
        let tokens = StravaTokens(accessToken: "A", refreshToken: "R", expiresAt: clock.addingTimeInterval(3600))
        return StravaUploader(
            client: StravaClient(transport: transport, secrets: MemorySecrets(tokens: tokens),
                                 now: { [clock] in clock }, sleep: { _ in }),
            sleep: { _ in })
    }

    private func ready() -> StravaHTTPResponse {
        StravaHTTPResponse(status: 201, body: try! JSONSerialization.data(withJSONObject:
            ["id": 5, "activity_id": 900, "status": "Your activity is ready.", "error": NSNull()]))
    }

    @Test("a ride with no mute costs no extra write")
    func noPutWhenNothingToChange() async throws {
        let transport = ScriptedTransport([ready()])
        let (workout, series) = workout(.cycling)
        _ = try await uploader(transport).send(workout, series: series) { _ in }
        #expect(await transport.paths() == ["POST /api/v3/uploads"])
    }

    @Test("mute and the sport correction share a single PUT")
    func oneCombinedPut() async throws {
        let transport = ScriptedTransport([ready(), StravaHTTPResponse(status: 200, body: Data("{}".utf8))])
        let (workout, series) = workout(.walking)
        _ = try await uploader(transport).send(workout, series: series, options: UploadOptions(muted: true)) { _ in }

        let puts = await transport.requests.filter { $0.method == "PUT" }
        #expect(puts.count == 1)
        let body = try JSONSerialization.jsonObject(with: try #require(puts.first?.body)) as? [String: Any]
        #expect(body?["sport_type"] as? String == "Walk")
        #expect(body?["hide_from_home"] as? Bool == true)
    }

    @Test("tags travel with the upload as Strava's commute and trainer flags")
    func flagsAtUpload() async throws {
        let transport = ScriptedTransport([ready()])
        let (workout, series) = workout(.cycling)
        _ = try await uploader(transport).send(
            workout, series: series, options: UploadOptions(flags: StravaFlags(commute: true, trainer: false))
        ) { _ in }
        let body = String(decoding: try #require(await transport.requests.first?.body), as: UTF8.self)
        #expect(body.contains("name=\"commute\"\r\n\r\n1\r\n"))
        #expect(body.contains("name=\"trainer\"\r\n\r\n0\r\n"))
    }

    @Test("a race goes in the one post-upload PUT, as workout_type")
    func raceAtUpload() async throws {
        let transport = ScriptedTransport([ready(), StravaHTTPResponse(status: 200, body: Data("{}".utf8))])
        let (workout, series) = workout(.running)
        _ = try await uploader(transport).send(
            workout, series: series, options: UploadOptions(flags: StravaFlags(commute: false, trainer: false, race: true))
        ) { _ in }
        let puts = await transport.requests.filter { $0.method == "PUT" }
        #expect(puts.count == 1)
        let body = try JSONSerialization.jsonObject(with: try #require(puts.first?.body)) as? [String: Any]
        #expect(body?["workout_type"] as? Int == 1)
    }

    @Test("a race tag on a walk sends no workout_type: Strava has none for it")
    func raceOnAWalk() async throws {
        let transport = ScriptedTransport([ready(), StravaHTTPResponse(status: 200, body: Data("{}".utf8))])
        let (workout, series) = workout(.walking)
        _ = try await uploader(transport).send(
            workout, series: series, options: UploadOptions(flags: StravaFlags(commute: false, trainer: false, race: true))
        ) { _ in }
        let put = try #require(await transport.requests.first { $0.method == "PUT" })
        let body = try JSONSerialization.jsonObject(with: try #require(put.body)) as? [String: Any]
        #expect(body?["workout_type"] == nil)
        #expect(body?["sport_type"] as? String == "Walk")
    }

    @Test("the activity list's workout type decodes into the race flag")
    func summaryRace() throws {
        let json = #"[{"id":1,"start_date":"2025-10-12T15:23:39Z","elapsed_time":15000,"workout_type":1},"#
            + #"{"id":2,"start_date":"2025-10-11T18:14:10Z","elapsed_time":2000,"workout_type":0},"#
            + #"{"id":3,"start_date":"2025-10-13T18:25:11Z","elapsed_time":2000,"workout_type":null}]"#
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let summaries = try decoder.decode([StravaActivitySummary].self, from: Data(json.utf8))
        #expect(summaries.map(\.flags.race) == [true, false, nil])
    }

    @Test("the activity list's flags decode")
    func summaryFlags() throws {
        let json = #"[{"id":1,"start_date":"2026-09-21T19:46:51Z","elapsed_time":600,"commute":true,"trainer":false}]"#
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let summary = try #require(try decoder.decode([StravaActivitySummary].self, from: Data(json.utf8)).first)
        #expect(summary.flags == StravaFlags(commute: true, trainer: false))
    }
}
