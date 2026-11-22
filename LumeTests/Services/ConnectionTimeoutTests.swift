import Foundation
@testable import Lume
import Testing

@MainActor
struct ConnectionTimeoutTests {
    @Test func `deadline returns before an uncooperative validation finishes`() async {
        let response = TaskResult<Int>()
        let provider = Task { try await response.value() }
        let validation = Task {
            try await LoginView.connectionTest(timeout: .milliseconds(10)) {
                try await provider.value
            }
        }
        await #expect(throws: LoginView.ConnectionTimeoutError.self) { try await validation.value }
        response.resolve(.success(1))
        _ = try? await provider.value
    }

    @Test func `cancelling validation returns without awaiting provider cooperation`() async throws {
        let response = TaskResult<Int>()
        let started = TaskResult<Void>()
        let provider = Task { try await response.value() }
        let validation = Task {
            try await LoginView.connectionTest {
                started.resolve(.success(()))
                return try await provider.value
            }
        }
        try await started.value()
        validation.cancel()
        await #expect(throws: CancellationError.self) { try await validation.value }
        response.resolve(.success(1))
        _ = try? await provider.value
    }
}
