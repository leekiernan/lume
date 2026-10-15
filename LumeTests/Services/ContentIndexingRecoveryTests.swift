import Foundation
@testable import Lume
import Testing

@MainActor
struct ContentIndexingRecoveryTests {
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
