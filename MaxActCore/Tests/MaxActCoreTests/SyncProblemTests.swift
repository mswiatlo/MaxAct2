import Foundation
import Testing

@testable import MaxActCore

@Suite struct SyncProblemTests {
    @Test("a refused connection means the server isn't running, not that the phone is missing")
    func refused() {
        #expect(SyncProblem(error: URLError(.cannotConnectToHost)) == .serverNotRunning)
        #expect(SyncProblem.serverNotRunning.advice.contains("start the server"))
    }

    @Test("no answer at all means the phone can't be reached")
    func unreachable() {
        for code in [URLError.Code.timedOut, .cannotFindHost, .networkConnectionLost, .notConnectedToInternet] {
            #expect(SyncProblem(error: URLError(code)) == .phoneUnreachable, "\(code)")
        }
        #expect(SyncProblem.phoneUnreachable.advice.contains("same Wi-Fi"))
    }

    @Test("401 and 403 mean the token; other statuses are the server's own errors")
    func http() {
        #expect(SyncProblem(error: MCPError.http(status: 401, body: "")) == .tokenRejected)
        #expect(SyncProblem(error: MCPError.http(status: 403, body: "")) == .tokenRejected)
        #expect(SyncProblem(error: MCPError.http(status: 500, body: "boom")) == .serverError(status: 500))
        #expect(SyncProblem.serverError(status: 500).title.contains("HTTP 500"))
    }

    @Test("protocol and decoding failures are an unexpected reply, keeping the detail")
    func unexpected() {
        let rpc = SyncProblem(error: MCPError.rpc(code: -32600, message: "Missing session"))
        guard case .unexpectedReply(let detail) = rpc else { Issue.record("got \(rpc)"); return }
        #expect(detail.contains("-32600"))
        #expect(rpc.advice.contains("-32600"))

        struct Odd: Error {}
        if case .unexpectedReply = SyncProblem(error: Odd()) {} else { Issue.record("an unknown error") }
    }

    @Test("an empty sync points at Health's sharing settings")
    func nothingReturned() {
        #expect(SyncProblem.nothingReturned.message.contains("Sharing ▸ Apps ▸ Health Auto Export"))
    }
}
