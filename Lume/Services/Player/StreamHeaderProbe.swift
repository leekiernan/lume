import Foundation
import os

/// Resolves exactly once on headers, error or caller cancellation. Never admits
/// a response body, including servers that ignore the single-byte Range request.
private nonisolated struct StreamProbeState {
    var finished = false
    var continuation: CheckedContinuation<HTTPURLResponse?, Never>?
    var session: URLSession?
}

final nonisolated class StreamHeaderProbe: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let state = OSAllocatedUnfairLock(initialState: StreamProbeState())

    func response(for request: URLRequest, configuration: URLSessionConfiguration) async -> HTTPURLResponse? {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let session: URLSession? = state.withLock { state in
                    guard !state.finished else { return nil }
                    let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
                    state.session = session
                    state.continuation = continuation
                    return session
                }
                guard let session else { continuation.resume(returning: nil); return }
                session.dataTask(with: request).resume()
            }
        } onCancel: { self.finish(nil) }
    }

    private func finish(_ response: HTTPURLResponse?) {
        let completion = state.withLock { state -> (CheckedContinuation<HTTPURLResponse?, Never>?, URLSession?) in
            guard !state.finished else { return (nil, nil) }
            state.finished = true
            defer { state.continuation = nil; state.session = nil }
            return (state.continuation, state.session)
        }
        completion.1?.invalidateAndCancel()
        completion.0?.resume(returning: response)
    }

    func urlSession(_: URLSession, dataTask _: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void)
    {
        finish(response as? HTTPURLResponse)
        completionHandler(.cancel)
    }

    func urlSession(_: URLSession, task _: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest _: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void)
    {
        finish(response)
        completionHandler(nil)
    }

    func urlSession(_: URLSession, task _: URLSessionTask, didCompleteWithError _: (any Error)?) {
        finish(nil)
    }
}
