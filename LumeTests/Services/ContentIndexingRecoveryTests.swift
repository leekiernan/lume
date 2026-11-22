import Foundation
@testable import Lume
import Testing

@MainActor
struct ContentIndexingRecoveryTests {
    #if DEBUG
        @Test func `a retired pass cannot publish progress or retire the replacement`() async throws {
            var attempts = 0
            var oldRelease: CheckedContinuation<Void, Never>?
            var newRelease: CheckedContinuation<Void, Never>?
            let oldFinished = TaskResult<Void>()
            let service = ContentIndexingService(runPass: { _, status in
                attempts += 1
                if attempts == 1 {
                    defer { oldFinished.resolve(.success(())) }
                    await withCheckedContinuation { oldRelease = $0 }
                    status.setPreparing()
                    status.update(indexed: 999, total: 999)
                    status.finish(indexed: 999, total: 999)
                    throw URLError(.cancelled)
                }
                status.update(indexed: 2, total: 3)
                await withCheckedContinuation { newRelease = $0 }
                status.finish(indexed: 3, total: 3)
            })
            try service.configure(container: makeTestContainer())
            service.kick()
            try await waitUntil { oldRelease != nil }
            service.reset()
            service.kick()
            try await waitUntil { newRelease != nil }
            oldRelease?.resume()
            try await oldFinished.value()
            #expect(service.state == .indexing)
            #expect(service.indexedCount == 2 && service.totalCount == 3)
            service.kick()
            #expect(attempts == 2, "the old defer must not release the new pass")
            newRelease?.resume()
            await service.waitForCurrentPass()
            #expect(service.state == .upToDate && service.indexedCount == 3)
        }
    #endif

    @Test func `exhausted model discovery can recover on a later kick`() async throws {
        var attempts = 0
        let service = ContentIndexingService(runPass: { _, status in
            attempts += 1
            if attempts == 1 { throw TextEmbedder.EmbedderError.modelUnavailable }
            status.finish(indexed: 1, total: 1)
        })
        try service.configure(container: makeTestContainer())
        service.kick()
        await service.waitForCurrentPass()
        #expect(service.state == .interrupted && attempts == 1)

        service.kick()
        await service.waitForCurrentPass()
        #expect(service.state == .upToDate && attempts == 2 && service.indexedCount == 1)
    }

    @Test func `duplicate kicks still coalesce while a pass is claimed`() async throws {
        var attempts = 0
        let service = ContentIndexingService(runPass: { _, status in
            attempts += 1
            status.finish(indexed: 0, total: 0)
        })
        try service.configure(container: makeTestContainer())
        service.kick()
        service.kick()
        await service.waitForCurrentPass()
        #expect(service.state == .upToDate && attempts == 1)
    }

    @Test func `asset preparation exhaustion retains its existing unavailable policy`() async throws {
        var attempts = 0
        let service = ContentIndexingService(runPass: { _, _ in
            attempts += 1
            throw TextEmbedder.EmbedderError.assetsUnavailable
        })
        try service.configure(container: makeTestContainer())
        service.kick()
        await service.waitForCurrentPass()
        #expect(service.state == .unavailable)
        service.kick()
        await service.waitForCurrentPass()
        #expect(attempts == 1)
    }
}
