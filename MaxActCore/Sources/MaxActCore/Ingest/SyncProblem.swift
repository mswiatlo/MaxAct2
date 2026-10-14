import Foundation

/// What went wrong with a sync, in terms the person at the Mac can act on.
///
/// The causes are few and each has one fix, but the raw errors don't say which: a phone on
/// another network and a phone whose server isn't running both surface as "Could not connect to
/// the server", which sends people looking at their Mac. The distinctions that matter:
///
/// - **Refused** (`cannotConnectToHost`): the phone answered and nothing was listening — the server
///   isn't started, or Health Auto Export went to the background and iOS suspended it.
/// - **Unreachable** (time-out, unknown host, network lost): the phone didn't answer at all — wrong
///   address, another Wi-Fi network, or asleep.
/// - **Token rejected** (HTTP 401/403).
/// - **Server error** (other HTTP statuses), and **unexpected reply** (protocol or decoding).
/// - **Nothing returned**: not an error at all — the sync succeeded with zero workouts. Per Health
///   Auto Export's own documentation that is indistinguishable from Health not letting it read
///   workouts, so it gets advice rather than a quiet "No new workouts".
public enum SyncProblem: Equatable, Sendable {
    case serverNotRunning
    case phoneUnreachable
    case tokenRejected
    case serverError(status: Int)
    case unexpectedReply(String)
    case nothingReturned

    public init(error: any Error) {
        if let mcp = error as? MCPError {
            switch mcp {
            case .http(401, _), .http(403, _): self = .tokenRejected
            case .http(let status, _): self = .serverError(status: status)
            case .transport(let detail): self = .unexpectedReply(detail)
            case .rpc, .missingSessionID, .malformedResult: self = .unexpectedReply(mcp.description)
            }
            return
        }
        if let url = error as? URLError {
            switch url.code {
            case .cannotConnectToHost: self = .serverNotRunning
            case .timedOut, .cannotFindHost, .dnsLookupFailed, .networkConnectionLost,
                 .notConnectedToInternet, .internationalRoamingOff, .dataNotAllowed:
                self = .phoneUnreachable
            default: self = .unexpectedReply(url.localizedDescription)
            }
            return
        }
        self = .unexpectedReply(error.localizedDescription)
    }

    /// One line: what happened.
    public var title: String {
        switch self {
        case .serverNotRunning: "The iPhone answered, but Health Auto Export's server isn't running."
        case .phoneUnreachable: "Can't reach the iPhone."
        case .tokenRejected: "Health Auto Export rejected the token."
        case .serverError(let status): "Health Auto Export reported an error (HTTP \(status))."
        case .unexpectedReply: "Health Auto Export's reply wasn't understood."
        case .nothingReturned: "Health Auto Export returned no workouts."
        }
    }

    /// What to do about it.
    public var advice: String {
        switch self {
        case .serverNotRunning:
            "Open Health Auto Export, start the server on its Server screen, and keep the app in "
                + "front with the phone unlocked until the sync finishes."
        case .phoneUnreachable:
            "Check that the iPhone is on the same Wi-Fi as this Mac, unlocked, with Health Auto "
                + "Export open — and that the address matches its Server screen."
        case .tokenRejected:
            "Copy the token again from Health Auto Export's Server screen. It changes if the server "
                + "is reset."
        case .serverError:
            "Try again. If it keeps happening, stop and restart the server in Health Auto Export."
        case .unexpectedReply(let detail):
            "Health Auto Export may be a newer version than MaxAct knows. (\(detail))"
        case .nothingReturned:
            "If you expected some, check that Health lets it read workouts: in the Health app, "
                + "Sharing ▸ Apps ▸ Health Auto Export."
        }
    }

    /// Title and advice together, for a banner.
    public var message: String { "\(title) \(advice)" }
}
