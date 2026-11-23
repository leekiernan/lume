import Foundation

/// Attempt budget only. Authentication refresh, error classification and
/// request/phase spacing belong to the provider, not to a universal request loop.
nonisolated struct ProviderRetryPolicy {
    let maxAttempts: Int

    static let catalog = ProviderRetryPolicy(maxAttempts: 3)

    /// Attempts are one-based; three attempts mean delays of 2s and 4s.
    func delay(afterFailedAttempt attempt: Int) -> Double? {
        guard attempt > 0, attempt < maxAttempts else { return nil }
        return pow(2, Double(attempt))
    }

    /// Runs `operation`, retrying a failure `isRetriable` accepts after the
    /// backoff above, while attempts remain. The provider decides what is
    /// transient; this owns only the loop. `onRetry` hears each failure about
    /// to be retried, with the attempt that failed and the delay; `onGiveUp`
    /// the one that is thrown. Cancellation during the backoff throws.
    func run<Result>(
        isRetriable: (Error) -> Bool,
        onRetry: (_ error: Error, _ attempt: Int, _ delay: Double) -> Void = { _, _, _ in },
        onGiveUp: (_ error: Error, _ attempts: Int) -> Void = { _, _ in },
        operation: () async throws -> Result
    ) async throws -> Result {
        var attempt = 0
        while true {
            attempt += 1
            do {
                return try await operation()
            } catch {
                guard !(error is CancellationError), isRetriable(error),
                      let delay = delay(afterFailedAttempt: attempt)
                else {
                    onGiveUp(error, attempt)
                    throw error
                }
                onRetry(error, attempt, delay)
                try await Task.sleep(for: .seconds(delay))
            }
        }
    }
}

extension ProviderRetryPolicy {
    /// A media-server page worth one more try: a dropped connection or a 5xx.
    /// Not a timeout: that page already waited the whole request timeout, and
    /// waiting it twice more would stall the library for minutes.
    static func isRetriableMediaServerFailure(network: Error?, status: Int?) -> Bool {
        if let status { return status >= 500 }
        guard let urlError = network as? URLError else { return false }
        return urlError.code != .timedOut && TransientNetworkError.isTransient(urlError)
    }
}

nonisolated extension JellyfinError {
    var isRetriable: Bool {
        switch self {
        case let .networkError(error): ProviderRetryPolicy.isRetriableMediaServerFailure(network: error, status: nil)
        case let .serverError(code): ProviderRetryPolicy.isRetriableMediaServerFailure(network: nil, status: code)
        case .invalidURL, .unauthorized, .notAMediaServer, .invalidResponse: false
        }
    }
}

nonisolated extension PlexError {
    var isRetriable: Bool {
        switch self {
        case let .networkError(error): ProviderRetryPolicy.isRetriableMediaServerFailure(network: error, status: nil)
        case let .serverError(code): ProviderRetryPolicy.isRetriableMediaServerFailure(network: nil, status: code)
        case .invalidURL, .unauthorized, .notAPlexServer, .invalidResponse: false
        }
    }
}

nonisolated enum ProviderRequestSpacing {
    static func remaining(
        minimum: Duration, since finishedAt: ContinuousClock.Instant?,
        now: ContinuousClock.Instant = .now
    ) -> Duration {
        guard let finishedAt else { return .zero }
        return max(.zero, min(minimum, minimum - (now - finishedAt)))
    }
}
