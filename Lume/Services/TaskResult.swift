import Foundation
import Synchronization

/// One result delivered once, with cancellation belonging to the waiter.
/// Owners decide whether abandoning a wait also cancels the underlying work.
final nonisolated class TaskResult<Value: Sendable>: Sendable {
    private enum State {
        case waiting(CheckedContinuation<Value, Error>?)
        case resolved(Result<Value, Error>)
    }

    private let state = Mutex(State.waiting(nil))

    @discardableResult
    func resolve(_ result: Result<Value, Error>) -> Bool {
        let delivery = state.withLock { state -> (Bool, CheckedContinuation<Value, Error>?) in
            guard case let .waiting(continuation) = state else { return (false, nil) }
            state = .resolved(result)
            return (true, continuation)
        }
        delivery.1?.resume(with: result)
        return delivery.0
    }

    func value() async throws -> Value {
        let value = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let resolved = state.withLock { state -> Result<Value, Error>? in
                    if case let .resolved(result) = state { return result }
                    state = .waiting(continuation)
                    return nil
                }
                if let resolved { continuation.resume(with: resolved) }
            }
        } onCancel: {
            self.resolve(.failure(CancellationError()))
        }
        try Task.checkCancellation()
        return value
    }

    /// Cancelling this wait does not cancel work shared by other callers.
    static func value(of task: Task<Value, Error>) async throws -> Value {
        let result = TaskResult()
        let delivery = Task { await result.resolve(task.result) }
        defer { delivery.cancel() }
        return try await result.value()
    }
}
