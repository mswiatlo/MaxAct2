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

    /// How far back the test looks for workouts: long enough that an active person has some.
    public static let lookback: TimeInterval = 14 * 86_400

    /// A sync waits up to ten minutes for a slow reply; a test that hung that long on a phone
    /// that isn't there would defeat the point.
    public static let timeout: TimeInterval = 15

    public static func run(_ source: HAEWorkoutSource, now: Date = .now) async -> ConnectionCheck {
        do {
            let info = try await source.connect()
            let result = try await source.listWorkouts(in: SyncWindow(start: now.addingTimeInterval(-lookback), end: now))
            return .connected(server: "\(info.name) \(info.version)",
                              recentWorkouts: result.workouts.count + result.failures.count)
        } catch {
            return .failed(SyncProblem(error: error))
        }
    }

    /// One line for the welcome sheet and Settings.
    public var summary: String {
        switch self {
        case .connected(let server, 0):
            "Connected to \(server), but it found no workouts in the last two weeks. "
                + SyncProblem.nothingReturned.advice
        case .connected(let server, let count):
            "Connected to \(server) — \(count) workout\(count == 1 ? "" : "s") in the last two weeks."
        case .failed(let problem):
            problem.message
        }
    }

    public var succeeded: Bool {
        if case .connected = self { true } else { false }
    }
}
