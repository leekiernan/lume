import Foundation
@testable import Lume
import Testing

@MainActor
struct TrackerAccountPermitTests {
    @Test func `an old queued event cannot fetch the replacements credentials`() async {
        let lifetime = TrackerAccountLifetime()
        let old = TrackerAccountPermit(account: lifetime)
        lifetime.invalidate()
        var lookups = 0
        let token = await old.accessToken { lookups += 1; return "new-account" }
        #expect(token == nil && lookups == 0)
        #expect(await TrackerAccountPermit(account: lifetime).accessToken { "new-account" } == "new-account")
    }

    @Test func `an account change during token refresh cannot authorize delivery`() async {
        let lifetime = TrackerAccountLifetime()
        let permit = TrackerAccountPermit(account: lifetime)
        let token = await permit.accessToken {
            lifetime.invalidate()
            return "replacement"
        }
        #expect(token == nil)
    }

    @Test func `restoring replacement credentials retires the sessions old permit`() async {
        let tracker = FakeTracker()
        tracker.storedTokens = FakeTokens(accessToken: "old", refreshToken: "old-r", issuedAt: 1)
        tracker.storedIdentity = alice
        let session = TrackerAccountSession(backend: FakeBackend(tracker: tracker))
        _ = await session.restore()
        let old = session.operationPermit
        tracker.storedTokens = FakeTokens(accessToken: "new", refreshToken: "new-r", issuedAt: 2)
        _ = await session.restore()
        #expect(!old.isCurrent)
        #expect(await old.accessToken(using: session.validAccessToken) == nil)
        #expect(await session.operationPermit.accessToken(using: session.validAccessToken) == "new")
    }
}
