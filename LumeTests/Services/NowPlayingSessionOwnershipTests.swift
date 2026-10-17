@testable import Lume
import Testing

struct NowPlayingSessionOwnershipTests {
    @Test func `old host teardown cannot clear a newer host`() {
        var ownership = NowPlayingSessionOwnership()
        let first = ActivityLease()
        let second = ActivityLease()
        let oldRequest = ownership.claim(first)
        let currentRequest = ownership.claim(second)
        let transition1 = ownership.release(first)
        #expect(!transition1)
        #expect(!ownership.accepts(oldRequest))
        #expect(ownership.accepts(currentRequest))
        let transition2 = ownership.release(second)
        #expect(transition2)
        #expect(!ownership.accepts(currentRequest))
        let transition3 = ownership.release(second)
        #expect(!transition3)
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
