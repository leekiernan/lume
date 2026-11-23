import Foundation
@testable import Lume
import Testing

struct ProviderRetryPolicyTests {
    @Test func `the existing catalog budget grants two backoffs and no fourth attempt`() {
        let policy = ProviderRetryPolicy.catalog
        #expect(policy.maxAttempts == 3)
        #expect(policy.delay(afterFailedAttempt: 1) == 2)
        #expect(policy.delay(afterFailedAttempt: 2) == 4)
        #expect(policy.delay(afterFailedAttempt: 3) == nil)
        #expect(policy.delay(afterFailedAttempt: 0) == nil)
        #expect(policy.delay(afterFailedAttempt: -1) == nil)
        #expect(ProviderRetryPolicy(maxAttempts: 1).delay(afterFailedAttempt: 1) == nil)
    }

    @Test func `phase spacing only waits for time not already paid by persistence`() {
        let finished = ContinuousClock.now
        #expect(ProviderRequestSpacing.remaining(minimum: .seconds(2), since: nil, now: finished) == .zero)
        #expect(ProviderRequestSpacing.remaining(minimum: .seconds(2), since: finished, now: finished + .seconds(1)) == .seconds(1))
        #expect(ProviderRequestSpacing.remaining(minimum: .seconds(2), since: finished, now: finished + .seconds(10)) == .zero)
        #expect(ProviderRequestSpacing.remaining(minimum: .seconds(2), since: finished, now: finished - .seconds(1)) == .seconds(2))
    }

    private struct Flaky: Error {
        var retriable = true
    }

    @Test func `run retries only what the provider calls transient, within the budget`() async throws {
        let policy = ProviderRetryPolicy(maxAttempts: 2)
        var calls = 0
        var retried: [Int] = []
        let value = try await policy.run(isRetriable: { ($0 as? Flaky)?.retriable == true }, onRetry: { _, attempt, _ in
            retried.append(attempt)
        }, operation: {
            calls += 1
            if calls == 1 { throw Flaky() }
            return 7
        })
        #expect(value == 7)
        #expect(retried == [1])

        calls = 0
        var gaveUp: Int?
        await #expect(throws: Flaky.self) {
            try await policy.run(isRetriable: { ($0 as? Flaky)?.retriable == true }, onGiveUp: { _, attempts in gaveUp = attempts }, operation: {
                calls += 1
                throw Flaky(retriable: false)
            })
        }
        #expect(calls == 1, "a permanent failure isn't retried")
        #expect(gaveUp == 1)
    }

    @Test func `a timed-out media server page is not retried, a dropped one is`() {
        #expect(!JellyfinError.networkError(URLError(.timedOut)).isRetriable)
        #expect(JellyfinError.networkError(URLError(.networkConnectionLost)).isRetriable)
        #expect(PlexError.serverError(503).isRetriable)
        #expect(!PlexError.serverError(404).isRetriable)
        #expect(!PlexError.unauthorized.isRetriable)
    }
}
