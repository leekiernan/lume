import Foundation
@testable import Lume
import Testing

@MainActor
@Suite(.serialized, .globalState)
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

    @Test func `a same account rotation preserves queued delivery but retires imports`() async {
        let tracker = FakeTracker()
        tracker.storedTokens = FakeTokens(accessToken: "old", refreshToken: "old-r", issuedAt: 1)
        tracker.storedIdentity = alice
        tracker.identityResponses = [alice, alice]
        let session = TrackerAccountSession(backend: FakeBackend(tracker: tracker))
        _ = await session.restore()
        let old = session.operationPermit
        let oldImport = session.importPermit
        tracker.storedTokens = FakeTokens(accessToken: "new", refreshToken: "new-r", issuedAt: 2)
        _ = await session.restore()
        #expect(old.isCurrent)
        #expect(!oldImport.isCurrent)
        #expect(await old.accessToken(using: session.operationAccessToken) == "new")
    }

    @Test func `a changed account with the same remembered identity cannot send an old event`() async {
        let tracker = FakeTracker()
        tracker.storedTokens = FakeTokens(accessToken: "old", refreshToken: "r", issuedAt: 1)
        tracker.storedIdentity = alice
        tracker.identityResponses = [alice, nil, FakeIdentity(username: "bob", scope: "fake:2")]
        let session = TrackerAccountSession(backend: FakeBackend(tracker: tracker))
        _ = await session.restore()
        let permit = session.operationPermit
        tracker.storedTokens = FakeTokens(accessToken: "new", refreshToken: "new-r", issuedAt: 2)
        _ = await session.restore()
        #expect(await permit.accessToken(using: session.operationAccessToken) == nil)
        #expect(!permit.isCurrent)
    }

    @Test func `disconnect and reconnect to the same account retire queued events`() async {
        let tracker = FakeTracker()
        tracker.storedTokens = FakeTokens(accessToken: "old", refreshToken: "r", issuedAt: 1)
        tracker.storedIdentity = alice
        tracker.identityResponses = [alice, alice]
        let session = TrackerAccountSession(backend: FakeBackend(tracker: tracker))
        _ = await session.restore()
        let permit = session.operationPermit
        await session.disconnect()
        tracker.storedTokens = FakeTokens(accessToken: "new", refreshToken: "new-r", issuedAt: 2)
        tracker.storedIdentity = alice
        _ = await session.restore()
        #expect(await permit.accessToken(using: session.operationAccessToken) == nil)
    }

    @Test func `a cloud rotation during a local refresh keeps a same account event`() async throws {
        let tracker = FakeTracker()
        tracker.storedTokens = FakeTokens(accessToken: "old", refreshToken: "old-r", issuedAt: 1)
        tracker.storedIdentity = alice
        tracker.identityResponses = [alice, alice]
        let session = TrackerAccountSession(backend: FakeBackend(tracker: tracker))
        _ = await session.restore()
        let permit = session.operationPermit
        var completion: CheckedContinuation<TrackerRefreshOutcome<FakeTokens>, Never>?
        tracker.refreshGate = { await withCheckedContinuation { completion = $0 } }
        tracker.storedTokens = FakeTokens(accessToken: "expired", refreshToken: "expired-r", issuedAt: 2, needsRefresh: true)
        let restoring = Task { await session.restore() }
        try await waitUntil { completion != nil }
        let oldRefresh = try #require(completion)
        let event = Task { await permit.accessToken(using: session.operationAccessToken) }
        await Task.yield()
        tracker.storedTokens = FakeTokens(accessToken: "cloud", refreshToken: "cloud-r", issuedAt: 3)
        _ = await session.restore()
        oldRefresh.resume(returning: .unavailable)
        _ = await restoring.value
        #expect(await event.value == "cloud")
        #expect(permit.isCurrent)
    }
}
