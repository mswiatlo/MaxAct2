import Foundation

/// A `URLSession` that never follows a redirect and stops a reply that grows past a limit
/// (issue 47). Used for both the phone and Strava.
///
/// - **Redirects:** neither link needs one, and following one would re-send the request — with its
///   `Authorization` header — to wherever a spoofed server pointed.
/// - **Size:** a server on the LAN could otherwise stream gigabytes into memory. The reply is
///   gathered chunk by chunk and abandoned past `limit`. Not with `bytes(for:)`: reading 5 MB a
///   byte at a time took 35 s in a debug build, against 0.02 s for `data(for:)` (measured).
public final class GuardedSession: Sendable {
    /// Far above anything real — a detail download is ~2.5 MB a workout — and far below trouble.
    public static let defaultLimit = 256 * 1024 * 1024

    private let session: URLSession
    private let delegate: Delegate

    public init(configuration: URLSessionConfiguration, limit: Int = defaultLimit) {
        delegate = Delegate(limit: limit)
        session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
    }

    deinit {
        // The session holds its delegate strongly; let both go once the work in flight is done.
        session.finishTasksAndInvalidate()
    }

    public func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let task = session.dataTask(with: request)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                delegate.register(task, continuation)
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
    }

    /// The reply grew past the limit.
    public struct TooLarge: Error, Equatable, CustomStringConvertible {
        public let limit: Int
        public var description: String { "the reply was larger than \(limit / 1_048_576) MB" }
    }

    private final class Delegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
        private struct Pending {
            var data = Data()
            var response: URLResponse?
            var failure: (any Error)?
            let continuation: CheckedContinuation<(Data, URLResponse), any Error>
        }

        let limit: Int
        private let lock = NSLock()
        private var pending: [Int: Pending] = [:]

        init(limit: Int) { self.limit = limit }

        func register(_ task: URLSessionTask, _ continuation: CheckedContinuation<(Data, URLResponse), any Error>) {
            lock.withLock { pending[task.taskIdentifier] = Pending(continuation: continuation) }
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
            completionHandler(nil)   // the redirect itself comes back as the reply
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                        completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
            let tooLarge = response.expectedContentLength > limit
            lock.withLock {
                pending[dataTask.taskIdentifier]?.response = response
                if tooLarge { pending[dataTask.taskIdentifier]?.failure = TooLarge(limit: limit) }
            }
            completionHandler(tooLarge ? .cancel : .allow)
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
            let over: Bool = lock.withLock {
                guard var entry = pending[dataTask.taskIdentifier] else { return false }
                entry.data.append(data)
                let over = entry.data.count > limit
                if over { entry.failure = TooLarge(limit: limit); entry.data = Data() }
                pending[dataTask.taskIdentifier] = entry
                return over
            }
            if over { dataTask.cancel() }
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
            guard let entry = lock.withLock({ pending.removeValue(forKey: task.taskIdentifier) }) else { return }
            if let failure = entry.failure {
                entry.continuation.resume(throwing: failure)
            } else if let error {
                entry.continuation.resume(throwing: error)
            } else if let response = entry.response ?? task.response {
                entry.continuation.resume(returning: (entry.data, response))
            } else {
                entry.continuation.resume(throwing: URLError(.badServerResponse))
            }
        }
    }
}
