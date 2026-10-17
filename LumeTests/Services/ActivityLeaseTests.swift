import Foundation
@testable import Lume
import Testing

struct ActivityLeaseTests {
    @Test func `acquiring and releasing are idempotent and owner qualified`() {
        var leases = ActivityLeases()
        let first = ActivityLease()
        let second = ActivityLease()
        leases.acquire(first)
        leases.acquire(first)
        leases.acquire(second)
        #expect(leases.release(first))
        #expect(!leases.release(first))
        #expect(leases.isActive)
        #expect(leases.release(second))
        #expect(!leases.isActive)
    }

    @MainActor @Test func `indexing remains paused until every playback host leaves`() {
        let service = ContentIndexingService(runPass: { _, _ in })
        let first = ActivityLease()
        let second = ActivityLease()
        service.beginPlayback(owner: first)
        service.beginPlayback(owner: second)
        service.endPlayback(owner: first)
        service.endPlayback(owner: first)
        #expect(service.isPlaybackActive)
        #expect(service.isBusyForIndexing)
        service.endPlayback(owner: second)
        #expect(!service.isPlaybackActive)
    }

    @MainActor @Test func `qoe suspension belongs to each multiview host`() throws {
        let name = "ActivityLeaseTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let qoe = PlaybackQoE(defaults: defaults)
        let first = ActivityLease()
        let second = ActivityLease()
        qoe.suspend(owner: first)
        qoe.suspend(owner: second)
        qoe.resume(owner: first)
        qoe.resume(owner: first)
        #expect(qoe.isSuspended)
        qoe.resume(owner: second)
        #expect(!qoe.isSuspended)
    }
}
