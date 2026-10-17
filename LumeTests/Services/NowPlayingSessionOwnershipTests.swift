@testable import Lume
import Testing

struct NowPlayingSessionOwnershipTests {
    @Test func `old host teardown cannot clear a newer host`() {
        var ownership = NowPlayingSessionOwnership()
        let first = ActivityLease()
        let second = ActivityLease()
        let oldRequest = ownership.claim(first)
        let currentRequest = ownership.claim(second)
        let oldHostReleased = ownership.release(first)
        #expect(!oldHostReleased)
        #expect(!ownership.accepts(oldRequest))
        #expect(ownership.accepts(currentRequest))
        let currentHostReleased = ownership.release(second)
        #expect(currentHostReleased)
        #expect(!ownership.accepts(currentRequest))
        let duplicateReleased = ownership.release(second)
        #expect(!duplicateReleased)
    }

    @Test func `same host stream swaps also revoke old asynchronous work`() {
        var ownership = NowPlayingSessionOwnership()
        let host = ActivityLease()
        let oldRequest = ownership.claim(host)
        let currentRequest = ownership.claim(host)
        #expect(!ownership.accepts(oldRequest))
        #expect(ownership.accepts(currentRequest))
    }
}
