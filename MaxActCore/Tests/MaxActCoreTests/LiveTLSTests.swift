import Foundation
import Testing

@testable import MaxActCore

/// Issue 48, against a real phone with HAE's server set to HTTPS:
///
/// ```
/// MAXACT_LIVE_HOST=https://<phone>:9000 MAXACT_LIVE_TOKEN=<token> \
///   MAXACT_LIVE_CA=~/Downloads/mcp-ca.pem swift test --filter LiveTLSTests
/// ```
///
/// With `MAXACT_LIVE_HOST` set to `http://…` instead (and HAE back on HTTP), only the timing runs,
/// for comparison.
enum LiveTLSConfiguration {
    static var caFile: URL? {
        ProcessInfo.processInfo.environment["MAXACT_LIVE_CA"].map {
            URL(filePath: ($0 as NSString).expandingTildeInPath)
        }
    }

    static var isConfigured: Bool { LiveConfiguration.isConfigured && caFile != nil }
    static var isHTTPS: Bool { LiveConfiguration.credentials?.host.lowercased().hasPrefix("https://") == true }
}

@Suite(.enabled(if: LiveTLSConfiguration.isConfigured), .serialized)
struct LiveTLSTests {
    private func pinned() throws -> PinnedCA {
        try PinnedCA(contents: Data(contentsOf: try #require(LiveTLSConfiguration.caFile)))
    }

    private func source(pinning ca: PinnedCA?) throws -> HAEWorkoutSource {
        let credentials = try #require(LiveConfiguration.credentials)
        return try #require(HAEWorkoutSource(address: credentials.host, token: credentials.token, pinnedCA: ca?.certificate))
    }

    @Test("time: handshake, three one-week lists, one detail")
    func timing() async throws {
        let ca = try pinned()
        print("CA \(ca.subjectSummary) \(ca.fingerprint)")
        let source = try source(pinning: LiveTLSConfiguration.isHTTPS ? ca : nil)

        var started = Date()
        try await source.connect()
        print("handshake: \(String(format: "%.2f", Date().timeIntervalSince(started)))s")

        let end = Date()
        var listed: HAEWorkoutDecoder.Result?
        for round in 1...3 {
            started = Date()
            listed = try await source.listWorkouts(in: SyncWindow(start: end.addingTimeInterval(-7 * 86_400), end: end))
            print("list \(round): \(listed?.workouts.count ?? 0) workouts in \(String(format: "%.2f", Date().timeIntervalSince(started)))s")
        }
        if let workout = listed?.workouts.map(\.workout).first(where: { $0.hasRoute || $0.kind.isDistanceBased }) {
            started = Date()
            let detail = try await source.fetchDetail(for: workout)
            print("detail: \(detail?.series.route.count ?? 0) route points in \(String(format: "%.2f", Date().timeIntervalSince(started)))s")
        }
    }

    @Test("without the pinned CA the phone is refused", .enabled(if: LiveTLSConfiguration.isHTTPS))
    func refusedWithoutPin() async throws {
        await #expect(throws: (any Error).self) { try await source(pinning: nil).connect() }
    }
}
