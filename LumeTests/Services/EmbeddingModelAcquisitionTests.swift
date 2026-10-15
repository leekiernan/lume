import Foundation
@testable import Lume
import Testing

struct EmbeddingModelAcquisitionTests {
    @Test func `an available model incurs no backoff`() async throws {
        var calls = 0
        var waits: [Duration] = []
        let model = try await EmbeddingModelAcquisition.acquire(lookup: { calls += 1; return 42 }, sleep: { waits.append($0) })
        #expect(model == 42 && calls == 1 && waits.isEmpty)
    }

    @Test func `cold discovery recovers after one or several nil results`() async throws {
        for misses in 1 ... 3 {
            var calls = 0
            var waits: [Duration] = []
            let model = try await EmbeddingModelAcquisition.acquire(lookup: {
                calls += 1
                return calls > misses ? "ready" : nil
            }, sleep: { waits.append($0) })
            #expect(model == "ready" && calls == misses + 1)
            #expect(waits == Array(EmbeddingModelAcquisition.retryDelays.prefix(misses)))
        }
    }

    @Test func `unavailability exhausts a finite budget and does not poison later acquisition`() async throws {
        var calls = 0
        var waits: [Duration] = []
        let missing: Int? = try await EmbeddingModelAcquisition.acquire(lookup: { calls += 1; return nil }, sleep: { waits.append($0) })
        #expect(missing == nil && calls == 4 && waits == [.milliseconds(100), .milliseconds(250), .seconds(1)])
        let recovered = try await EmbeddingModelAcquisition.acquire(lookup: { 42 }, sleep: { _ in Issue.record("Unexpected backoff") })
        #expect(recovered == 42)
    }

    @Test func `an empty retry schedule makes exactly one lookup`() async throws {
        var calls = 0
        let missing: Int? = try await EmbeddingModelAcquisition.acquire(lookup: { calls += 1; return nil }, retryDelays: [],
                                                                        sleep: { _ in Issue.record("Unexpected backoff") })
        #expect(missing == nil && calls == 1)
    }

    @Test func `cancellation before acquisition performs no lookup`() async {
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await EmbeddingModelAcquisition.acquire(lookup: {
                Issue.record("Cancelled acquisition made a lookup")
                return 42
            }, sleep: { _ in Issue.record("Cancelled acquisition waited") })
        }
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    @Test func `cancellation during backoff prevents another lookup`() async {
        let task = Task {
            var calls = 0
            do {
                let _: Int? = try await EmbeddingModelAcquisition.acquire(lookup: { calls += 1; return nil }, sleep: { _ in
                    withUnsafeCurrentTask { $0?.cancel() }
                })
                Issue.record("Cancellation did not propagate")
            } catch is CancellationError {
                #expect(calls == 1)
            } catch {
                Issue.record(error)
            }
        }
        await task.value
    }

    @Test func `cancellation during a successful lookup does not publish a model`() async {
        let task = Task {
            try await EmbeddingModelAcquisition.acquire(lookup: {
                withUnsafeCurrentTask { $0?.cancel() }
                return 42
            }, sleep: { _ in Issue.record("Unexpected backoff") })
        }
        await #expect(throws: CancellationError.self) { try await task.value }
    }
}
