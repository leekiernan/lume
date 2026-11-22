//
//  LoginView+ConnectionTimeout.swift
//  Lume
//
//  Split out of LoginView.swift to keep that file under the 600-line lint cap.
//

import SwiftUI

// MARK: - Connection-test timeout

extension LoginView {
    struct ConnectionTimeoutError: LocalizedError {
        var errorDescription: String? {
            String(localized: "The connection timed out. Check the URL and your network, then try again.")
        }
    }

    /// Runs an add-playlist connection test under an overall deadline, cancelling
    /// the in-flight request and surfacing a timeout when it's exceeded.
    ///
    /// Each client has its own per-request timeout and (for Xtream) retry/backoff
    /// tuned for *sync*, where retries matter; left unbounded, a wrong URL or
    /// dead host can hang the add sheet for ~30–90s on a spinner with no way out.
    /// This caps the test (default 20s) without weakening the sync path.
    /// The deadline settles independently of cancellation-cooperation by a
    /// provider. Callers commit model changes only after this returns.
    static func connectionTest<Value: Sendable>(timeout: Duration = .seconds(20), _ operation: @escaping () async throws -> Value) async throws -> Value {
        let result = TaskResult<Value>()
        let work = Task {
            do {
                try await result.resolve(.success(operation()))
            } catch {
                result.resolve(.failure(error))
            }
        }
        let watchdog = Task {
            do { try await Task.sleep(for: timeout) } catch { return }
            result.resolve(.failure(ConnectionTimeoutError()))
            work.cancel()
        }
        defer {
            watchdog.cancel()
            work.cancel()
        }
        return try await result.value()
    }
}
