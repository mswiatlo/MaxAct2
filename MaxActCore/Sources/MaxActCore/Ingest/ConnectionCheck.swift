import Foundation

/// "Test Connection": is the phone reachable, is the token accepted, and can Health Auto Export
/// read workouts — answered before someone commits to an hour-long sync.
///
/// Runs the handshake and lists the tools (both authenticated), then asks for the last
/// ``lookback`` of workouts. That last step is what makes it a real test: it exercises the same
/// tool a sync uses, and its count tells "connected, workouts flowing" from "connected, but Health
/// isn't sharing workouts with it" — which looks like success to every other check.
public enum ConnectionCheck: Equatable, Sendable {
    case connected(server: String, recentWorkouts: Int)
    case failed(SyncProblem)

    /// How far back the test looks for workouts. A week, not two: listing is slow on the phone's
    /// side — measured on a real one, 1 day took ~3 s, 7 days 11–16 s, 14 days 19–21 s — and the
    /// week is enough to show workouts flowing for anyone active.
    public static let lookback: TimeInterval = 7 * 86_400

    /// The handshake's deadline: it answers in 0.05–0.6 s (measured), so an absent phone is
    /// reported within seconds.
    public static let connectDeadline: TimeInterval = 10

    /// The per-request timeout for the source the check runs on, covering the slow listing. A
    /// single 15 s limit for everything, as first built, cut off a healthy phone mid-listing.
    public static let requestTimeout: TimeInterval = 90

    /// - Parameter onConnected: called with the server's name once the handshake succeeds, so the
    ///   UI can say what it's waiting for during the listing.
    public static func run(
        _ source: HAEWorkoutSource, now: Date = .now, connectDeadline: TimeInterval = connectDeadline,
        onConnected: @Sendable (String) async -> Void = { _ in }
    ) async -> ConnectionCheck {
        do {
            let info = try await withDeadline(connectDeadline) { try await source.connect() }
            let server = "\(info.name) \(info.version)"
            await onConnected(server)
            let result = try await source.listWorkouts(in: SyncWindow(start: now.addingTimeInterval(-lookback), end: now))
            return .connected(server: server, recentWorkouts: result.workouts.count + result.failures.count)
        } catch {
            return .failed(SyncProblem(error: error))
        }
    }

    /// Runs `operation`, failing with `URLError(.timedOut)` — what an unanswered request reports —
    /// if it takes longer than `seconds`. The loser is cancelled, which cancels its request.
    static func withDeadline<T: Sendable>(
        _ seconds: TimeInterval, _ operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(for: .seconds(seconds))
                throw URLError(.timedOut)
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else { throw URLError(.timedOut) }
            return first
        }
    }

    /// One line for the welcome sheet and Settings.
    public var summary: String {
        switch self {
        case .connected(let server, 0):
            "Connected to \(server), but it found no workouts in the last week. "
                + SyncProblem.nothingReturned.advice
        case .connected(let server, let count):
            "Connected to \(server) — \(count) workout\(count == 1 ? "" : "s") in the last week."
        case .failed(let problem):
            problem.message
        }
    }

    public var succeeded: Bool {
        if case .connected = self { true } else { false }
    }
}
