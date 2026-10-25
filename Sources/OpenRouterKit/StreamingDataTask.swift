// A request's response, then its body as it arrives: what Apple's
// `URLSession.bytes(for:)` gives, from a data task's delegate, which every
// Foundation has (Linux's has no `bytes`).

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Synchronization

/// One request, read as it arrives. Its delegate calls come on the
/// session's own queue: what they hand on goes through a continuation,
/// and the one not yet resumed is kept in a `Mutex`.
final class StreamingDataTask: NSObject, URLSessionDataDelegate, Sendable {
    /// Waiting for the response, until it or a failure comes.
    private let waiting = Mutex<CheckedContinuation<HTTPURLResponse, any Error>?>(nil)
    /// The body's pieces, as they arrive.
    let body: AsyncThrowingStream<Data, any Error>
    private let pieces: AsyncThrowingStream<Data, any Error>.Continuation
    private let task = Mutex<URLSessionDataTask?>(nil)

    override init() {
        (body, pieces) = AsyncThrowingStream.makeStream(of: Data.self)
        super.init()
        // Whoever reads the body stops reading (its task cancelled, or it
        // is done with it): the request stops too.
        pieces.onTermination = { [weak self] _ in self?.cancel() }
    }

    /// Starts the request and waits for its response; the body follows in
    /// `body`. Cancelled while it waits, the request is cancelled.
    func start(_ request: URLRequest, configuration: URLSessionConfiguration) async throws -> HTTPURLResponse {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                waiting.withLock { $0 = continuation }
                // The session holds its delegate until it is let go of,
                // which it is once its one task is done.
                let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
                let task = session.dataTask(with: request)
                self.task.withLock { $0 = task }
                task.resume()
                session.finishTasksAndInvalidate()
            }
        } onCancel: {
            cancel()
        }
    }

    func cancel() {
        task.withLock { $0 }?.cancel()
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
        let continuation = waiting.withLock { waiting in
            defer { waiting = nil }
            return waiting
        }
        if let http = response as? HTTPURLResponse {
            continuation?.resume(returning: http)
            completionHandler(.allow)
        } else {
            // Not an answer from an HTTP server: it has no status to call a
            // success.
            continuation?.resume(throwing: URLError(.badServerResponse))
            completionHandler(.cancel)
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        pieces.yield(data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        let continuation = waiting.withLock { waiting in
            defer { waiting = nil }
            return waiting
        }
        if let continuation {
            // Over before any response came.
            continuation.resume(throwing: error ?? URLError(.badServerResponse))
        }
        pieces.finish(throwing: error)
    }
}
