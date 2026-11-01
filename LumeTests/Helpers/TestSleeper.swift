import Foundation

/// A cancellable deadline the test releases explicitly, independent of load.
actor TestSleeper {
    nonisolated let requests: AsyncStream<Duration>
    private let requested: AsyncStream<Duration>.Continuation
    private var pending: [UUID: CheckedContinuation<Void, Error>] = [:]

    init() {
        (requests, requested) = AsyncStream.makeStream()
    }

    func sleep(_ duration: Duration) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else {
                    pending[id] = continuation
                    requested.yield(duration)
                }
            }
        } onCancel: {
            Task { await self.cancel(id) }
        }
    }

    func advance() {
        let continuations = Array(pending.values)
        pending.removeAll()
        for continuation in continuations {
            continuation.resume()
        }
    }

    private func cancel(_ id: UUID) {
        pending.removeValue(forKey: id)?.resume(throwing: CancellationError())
    }
}
