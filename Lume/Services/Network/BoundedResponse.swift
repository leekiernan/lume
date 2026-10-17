//
//  BoundedResponse.swift
//  Lume
//
//  An HTTP body read with its size limit enforced while it arrives, not after
//  `data(for:)` has collected all of it: a declared `Content-Length` over the
//  limit is refused before any body is read, and an undeclared body is
//  cancelled the moment it passes the limit. Peak memory is then the limit
//  plus one network chunk, whatever the server sends.
//
//  It runs on the caller's session, so connection reuse, cookies and caching
//  are the session's own, and a session delegate (`ArtworkRedirectPolicy`)
//  still decides redirects: the per-task delegate here implements only the
//  data callbacks.
//

import Foundation
import Synchronization

nonisolated enum BoundedResponse {
    struct TooLarge: Error, Equatable {
        let limit: Int
    }

    /// The body and response for `request`, or `TooLarge` once the body
    /// passes `limit` bytes. Cancelling the calling task cancels the request.
    static func data(for request: URLRequest, session: URLSession, limit: Int) async throws -> (Data, URLResponse) {
        let reader = BoundedResponseReader(limit: limit)
        let task = session.dataTask(with: request)
        task.delegate = reader
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                reader.start(task, continuation: continuation)
            }
        } onCancel: {
            task.cancel()
        }
    }
}

/// One bounded read's delegate: the body so far, and the caller waiting on it.
private final nonisolated class BoundedResponseReader: NSObject, URLSessionDataDelegate, Sendable {
    private struct State {
        var body = Data()
        var response: URLResponse?
        var tooLarge = false
        var continuation: CheckedContinuation<(Data, URLResponse), Error>?
    }

    private let limit: Int
    private let state = Mutex(State())

    init(limit: Int) {
        self.limit = limit
    }

    func start(_ task: URLSessionDataTask, continuation: CheckedContinuation<(Data, URLResponse), Error>) {
        state.withLock { $0.continuation = continuation }
        // Cancelled before it started: resume still runs the task, which
        // completes at once with `cancelled`.
        task.resume()
    }

    func urlSession(_: URLSession, dataTask _: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void)
    {
        let declared = response.expectedContentLength
        let allowed = declared <= Int64(limit)
        state.withLock {
            $0.response = response
            $0.tooLarge = !allowed
            // Only what the limit allows: a lying Content-Length can't
            // make this reserve more.
            if allowed, declared > 0 { $0.body.reserveCapacity(Int(declared)) }
        }
        completionHandler(allowed ? .allow : .cancel)
    }

    func urlSession(_: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let overflowed = state.withLock { state -> Bool in
            guard !state.tooLarge else { return false }
            guard state.body.count + data.count <= limit else {
                state.tooLarge = true
                state.body = Data()
                return true
            }
            state.body.append(data)
            return false
        }
        if overflowed { dataTask.cancel() }
    }

    func urlSession(_: URLSession, task _: URLSessionTask, didCompleteWithError error: Error?) {
        let (continuation, result) = state.withLock { state -> (CheckedContinuation<(Data, URLResponse), Error>?, Result<(Data, URLResponse), Error>) in
            defer { state.continuation = nil }
            let result: Result<(Data, URLResponse), Error> = if state.tooLarge {
                .failure(BoundedResponse.TooLarge(limit: limit))
            } else if let error {
                .failure(error)
            } else if let response = state.response {
                .success((state.body, response))
            } else {
                .failure(URLError(.badServerResponse))
            }
            return (state.continuation, result)
        }
        continuation?.resume(with: result)
    }
}
