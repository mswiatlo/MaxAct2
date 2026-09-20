import Foundation
import Testing

@testable import MaxActCore

/// Runs against a real phone. Skipped unless both variables are set, so `swift test` stays
/// hermetic and fast:
///
/// ```
/// MAXACT_LIVE_HOST=10.0.0.158 MAXACT_LIVE_TOKEN=<token> swift test --filter LiveMCPTests
/// ```
///
/// Worth keeping rather than deleting after Phase 2: mocks can only prove the client is
/// self-consistent. Everything that actually bit us in Phase 1 — the session handshake, the
/// doubly-encoded tool result, `includeRoutes` defaulting to false, units shifting under a
/// settings change — is invisible to a mock and visible here.
///
/// Health Auto Export must be open and foregrounded on an unlocked phone.
enum LiveConfiguration {
    static var credentials: (host: String, token: String)? {
        let environment = ProcessInfo.processInfo.environment
        guard let host = environment["MAXACT_LIVE_HOST"],
              let token = environment["MAXACT_LIVE_TOKEN"]
        else { return nil }
        return (host, token)
    }

    static var isConfigured: Bool { credentials != nil }
}

/// Lives at file scope because a `@Suite` condition cannot reference a type nested inside the
/// suite it annotates.
@Suite(.enabled(if: LiveConfiguration.isConfigured))
struct LiveMCPTests {
    private func source() throws -> HAEWorkoutSource {
        let credentials = try #require(LiveConfiguration.credentials)
        return HAEWorkoutSource(host: credentials.host, token: credentials.token)
    }

    @Test("the handshake succeeds and the server offers get_workouts")
    func connects() async throws {
        let info = try await source().connect()
        #expect(info.name.isEmpty == false)
        print("connected to \(info.name) \(info.version), protocol \(info.protocolVersion)")
    }

    @Test("a one-week list window decodes without failures")
    func listsAWeek() async throws {
        let source = try source()
        try await source.connect()

        let end = Date()
        let window = SyncWindow(start: end.addingTimeInterval(-7 * 24 * 3600), end: end)
        let started = Date()
        let result = try await source.listWorkouts(in: window)
        let elapsed = Date().timeIntervalSince(started)

        print("listed \(result.workouts.count) workouts in \(String(format: "%.1f", elapsed))s")
        for failure in result.failures {
            print("  FAILED \(failure.workoutID ?? "?"): \(failure.underlying)")
        }
        #expect(result.isCompleteSuccess, "a real payload should decode cleanly")

        // The list pass must not be paying for routes.
        #expect(result.workouts.allSatisfy { $0.series.route.isEmpty })
    }

    @Test("detail for one workout carries a route and second-resolution heart rate")
    func fetchesDetail() async throws {
        let source = try source()
        try await source.connect()

        let end = Date()
        let listed = try await source.listWorkouts(
            in: SyncWindow(start: end.addingTimeInterval(-14 * 24 * 3600), end: end)
        )
        guard let candidate = listed.workouts.map(\.workout).first(where: { $0.hasRoute || $0.kind.isDistanceBased }) else {
            Issue.record("no suitable workout in the last 14 days to fetch detail for")
            return
        }

        let detail = try await #require(source.fetchDetail(for: candidate))
        print("""
            detail for \(candidate.kind.displayName) on \(candidate.start): \
            \(detail.series.route.count) route points, \(detail.series.heartRate.count) HR samples
            """)
        #expect(detail.workout.id == candidate.id)
        #expect(!detail.series.heartRate.isEmpty)

        // "seconds" aggregation should give roughly 5 s buckets, not the 60 s default.
        if detail.series.heartRate.count > 10 {
            let dates = detail.series.heartRate.map(\.date).sorted()
            let gaps = zip(dates, dates.dropFirst()).map { $1.timeIntervalSince($0) }.filter { $0 > 0 }
            let median = gaps.sorted()[gaps.count / 2]
            print("  median HR interval: \(median)s")
            #expect(median <= 15, "expected seconds-resolution heart rate, got \(median)s buckets")
        }
    }
}
