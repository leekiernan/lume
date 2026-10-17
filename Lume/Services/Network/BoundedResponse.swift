//
//  BoundedResponse.swift
//  Lume
//
//  An HTTP body read with its size limit enforced while it arrives, not after
//  `data(for:)` has collected all of it: a declared `Content-Length` over the
//  limit is refused before any body is read, and an undeclared body is
//  cancelled the moment it passes the limit. This bounds the body retained
//  by this reader, not Foundation's buffering, decompression or caches.
//
//  It runs on the caller's session, so connection reuse, cookies and caching
//  are the session's own, and a session delegate (`ArtworkRedirectPolicy`)
//  still decides redirects: the per-task delegate here implements only the
//  data callbacks.
//

import Foundation
import Synchronization

nonisolated enum BoundedResponse {
    enum BodyPolicy {
        case all
        /// Preserve the status but discard error bodies before allocating them.
        case successful
    }

    struct TooLarge: Error, Equatable {
        let limit: Int
    }

    /// The body and response for `request`, or `TooLarge` once the body
    /// passes `limit` bytes. Cancelling the calling task cancels the request.
    static func data(for request: URLRequest, session: URLSession, limit: Int, bodyPolicy: BodyPolicy = .all) async throws -> (Data, URLResponse) {
        precondition(limit >= 0)
        let reader = BoundedResponseReader(limit: limit, method: request.httpMethod, bodyPolicy: bodyPolicy)
        let task = session.dataTask(with: request)
        task.delegate = reader
        let result = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                reader.start(task, continuation: continuation)
            }
        } onCancel: {
            reader.cancel(task)
        }
        guard !Task.isCancelled else { throw URLError(.cancelled) }
        return result
    }
}

/// One bounded read's delegate: the body so far, and the caller waiting on it.
private final nonisolated class BoundedResponseReader: NSObject, URLSessionDataDelegate, Sendable {
    private enum Disposition { case collect, discard, reject }
    private typealias ReadResult = Result<(Data, URLResponse), Error>
    private struct State {
        var body = Data()
        var response: URLResponse?
        var disposition = Disposition.collect
        var callerCancelled = false
        var continuation: CheckedContinuation<(Data, URLResponse), Error>?
        var result: ReadResult?
    }

    private let limit: Int
    private let method: String?
    private let bodyPolicy: BoundedResponse.BodyPolicy
    private let state = Mutex(State())

    init(limit: Int, method: String?, bodyPolicy: BoundedResponse.BodyPolicy) {
        self.limit = limit
        self.method = method
        self.bodyPolicy = bodyPolicy
    }

    func start(_ task: URLSessionDataTask, continuation: CheckedContinuation<(Data, URLResponse), Error>) {
        let completed = state.withLock { state -> ReadResult? in
            if let result = state.result { return result }
            state.continuation = continuation
            return nil
        }
        if let completed {
            continuation.resume(with: completed)
            return
        }
        task.resume()
    }

    func cancel(_ task: URLSessionDataTask) {
        state.withLock { $0.callerCancelled = true }
        task.cancel()
    }

    func urlSession(_: URLSession, dataTask _: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void)
    {
        let declared = response.expectedContentLength
        let status = (response as? HTTPURLResponse)?.statusCode
        let bodyless = method?.uppercased() == "HEAD" || status.map { (100 ..< 200).contains($0) || [204, 205, 304].contains($0) } == true
        let unwanted = bodyPolicy == .successful && status.map { !(200 ..< 300).contains($0) } == true
        let disposition: Disposition = bodyless || unwanted ? .discard : declared > Int64(limit) ? .reject : .collect
        state.withLock {
            $0.response = response
            $0.disposition = disposition
            // Only what the limit allows: a lying Content-Length can't
            // make this reserve more.
            if disposition == .collect, declared > 0 { $0.body.reserveCapacity(Int(declared)) }
        }
        // A bodyless response completes on its own; cancelling it would only
        // close a connection the session could reuse.
        completionHandler(disposition == .collect || bodyless ? .allow : .cancel)
    }

    func urlSession(_: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let overflowed = state.withLock { state -> Bool in
            guard state.disposition == .collect else { return false }
            guard data.count <= limit - state.body.count else {
                state.disposition = .reject
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
            let result: ReadResult = if state.callerCancelled {
                .failure(URLError(.cancelled))
            } else if state.disposition == .reject {
                .failure(BoundedResponse.TooLarge(limit: limit))
            } else if state.disposition == .discard, let response = state.response {
                .success((Data(), response))
            } else if let error {
                .failure(error)
            } else if let response = state.response {
                .success((state.body, response))
            } else {
                .failure(URLError(.badServerResponse))
            }
            state.result = result
            return (state.continuation, result)
        }
        continuation?.resume(with: result)
    }
}
