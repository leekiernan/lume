import Foundation
@testable import Lume
import Testing

@MainActor
struct ConnectionTimeoutTests {
    @Test func `deadline returns before an uncooperative validation finishes`() async {
        var release: CheckedContinuation<Int, Never>?
        let validation = Task {
            try await LoginView.connectionTest(timeout: .milliseconds(10)) {
                await withCheckedContinuation { release = $0 }
            }
        }
        await #expect(throws: LoginView.ConnectionTimeoutError.self) { try await validation.value }
        #expect(release != nil)
        release?.resume(returning: 1)
    }

    @Test func `cancelling validation returns without awaiting provider cooperation`() async throws {
        var release: CheckedContinuation<Int, Never>?
        var cancelledReturned = false
        let validation = Task {
            do {
                _ = try await LoginView.connectionTest {
                    await withCheckedContinuation { release = $0 }
                }
                Issue.record("Cancelled validation succeeded")
            } catch { #expect(error is CancellationError) }
            cancelledReturned = true
        }
        try await waitUntil { release != nil }
        validation.cancel()
        try await waitUntil { cancelledReturned }
        #expect(cancelledReturned)
        release?.resume(returning: 1)
        await validation.value
    }
}
