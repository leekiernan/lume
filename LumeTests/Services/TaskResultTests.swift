import Foundation
@testable import Lume
import Testing

struct TaskResultTests {
    @Test func `first result wins even when it arrives before the waiter`() async throws {
        let result = TaskResult<Int>()
        #expect(result.resolve(.success(1)))
        #expect(!result.resolve(.success(2)))
        #expect(try await result.value() == 1)
    }

    @Test func `cancellation before registration cannot strand a waiter`() async {
        let entered = TaskResult<Void>()
        let release = TaskResult<Void>()
        let result = TaskResult<Int>()
        let waiter = Task {
            entered.resolve(.success(()))
            _ = try? await release.value()
            return try await result.value()
        }
        _ = try? await entered.value()
        waiter.cancel()
        await #expect(throws: CancellationError.self) { try await waiter.value }
    }
}
