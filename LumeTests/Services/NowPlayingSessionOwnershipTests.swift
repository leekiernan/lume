@testable import Lume
import Testing

struct NowPlayingSessionOwnershipTests {
    @Test func `old host teardown cannot clear a newer host`() {
        var ownership = NowPlayingSessionOwnership()
        let first = ActivityLease()
        let second = ActivityLease()
        let oldRequest = ownership.claim(first)
        let currentRequest = ownership.claim(second)
        let releasedOld = ownership.release(first)
        #expect(!releasedOld)
        #expect(!ownership.accepts(oldRequest))
        #expect(ownership.accepts(currentRequest))
        let releasedCurrent = ownership.release(second)
        #expect(releasedCurrent)
        #expect(!ownership.accepts(currentRequest))
        let releasedAgain = ownership.release(second)
        #expect(!releasedAgain)
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
