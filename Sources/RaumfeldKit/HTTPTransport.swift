import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Abstraction over the HTTP layer so the library can be tested without a network.
///
/// Implementations should stop the request when the calling task is cancelled.
public protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

/// The default transport, backed by `URLSession`.
///
/// It uses two sessions: one for ordinary requests, and one with a long idle
/// timeout for the host's long-poll requests. A request goes to the long-poll
/// session when its `timeoutInterval` is above `longPollThreshold`. That way the
/// session-level timeout can never cut a long poll short.
public final class URLSessionTransport: HTTPTransport, @unchecked Sendable {
    // URLSession is thread-safe; the unchecked conformance is only needed on
    // platforms where it is not annotated as Sendable.

    /// A transport shared by all clients that don't pass their own. Sharing it
    /// avoids creating (and leaking) URLSessions whenever a client is recreated.
    public static let shared = URLSessionTransport()

    /// Requests with a longer `timeoutInterval` than this use the long-poll session.
    public static let longPollThreshold: TimeInterval = 60

    let session: URLSession
    let longPollSession: URLSession
    private let ownsSessions: Bool

    /// Creates a transport. If `session` is given, it is used for every request
    /// and the caller remains responsible for its timeouts and lifetime.
    public init(session: URLSession? = nil) {
        if let session {
            self.session = session
            self.longPollSession = session
            ownsSessions = false
        } else {
            self.session = URLSession(configuration: Self.configuration(requestTimeout: 15))
            // A little more than the longest long poll the client issues.
            self.longPollSession = URLSession(configuration: Self.configuration(requestTimeout: 20 * 60))
            ownsSessions = true
        }
    }

    deinit {
        if ownsSessions {
            session.invalidateAndCancel()
            longPollSession.invalidateAndCancel()
        }
    }

    private static func configuration(requestTimeout: TimeInterval) -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = requestTimeout
        configuration.timeoutIntervalForResource = 60 * 60
        configuration.httpMaximumConnectionsPerHost = 8
        return configuration
    }

    func session(for request: URLRequest) -> URLSession {
        request.timeoutInterval > Self.longPollThreshold ? longPollSession : session
    }

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let box = TaskBox()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                let task = session(for: request).dataTask(with: request) { data, response, error in
                    if let error {
                        if (error as? URLError)?.code == .cancelled {
                            continuation.resume(throwing: CancellationError())
                        } else {
                            continuation.resume(throwing: error)
                        }
                    } else if let http = response as? HTTPURLResponse {
                        continuation.resume(returning: (data ?? Data(), http))
                    } else {
                        continuation.resume(throwing: RaumfeldError.invalidResponse("not an HTTP response"))
                    }
                }
                box.start(task)
            }
        } onCancel: {
            box.cancel()
        }
    }
}

/// Holds a data task so a cancellation that races with its creation still cancels it.
private final class TaskBox: @unchecked Sendable {
    private let lock = NSLock()
    private var task: URLSessionTask?
    private var cancelled = false

    func start(_ task: URLSessionTask) {
        lock.lock()
        self.task = task
        let cancelled = self.cancelled
        lock.unlock()
        task.resume()
        // Cancelling a resumed task always calls its completion handler.
        if cancelled { task.cancel() }
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let task = self.task
        lock.unlock()
        task?.cancel()
    }
}
