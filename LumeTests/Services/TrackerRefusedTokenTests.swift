//
//  TrackerRefusedTokenTests.swift
//  LumeTests
//
//  An access token the service refuses before its expiry date — Simkl ends
//  the previous token the moment any device refreshes the shared pair — is
//  refreshed and the request sent again, instead of every request failing
//  until the local clock says the token is stale.
//

import Foundation
@testable import Lume
import Testing

@MainActor
struct TrackerRefusedTokenTests {
    private let renewed = FakeTokens(accessToken: "b", refreshToken: "r", issuedAt: 2)

    private func connected(refusing tokens: Set<String> = []) async -> (FakeTracker, TrackerAccountSession<FakeBackend>, TrackerMutationQueue<FakeBackend>) {
        let tracker = FakeTracker()
        tracker.storedTokens = FakeTokens(accessToken: "a", refreshToken: "r", issuedAt: 1)
        tracker.identityResponses = [alice, alice]
        let defaults = UserDefaults(suiteName: "TrackerRefusedTokenTests.\(UUID().uuidString)")!
        let outbox = TrackerMutationOutbox(defaults: defaults, storageKey: FakeBackend.outboxStorageKey)
        let session = TrackerAccountSession(backend: FakeBackend(tracker: tracker), identityRetryDelay: .milliseconds(20))
        let queue = TrackerMutationQueue(session: session, outbox: outbox)
        tracker.refusedTokens = tokens
        tracker.refreshResponse = .refreshed(renewed)
        _ = await session.restore()
        return (tracker, session, queue)
    }

    @Test func `a refused token at restore is refreshed and the account confirmed`() async {
        let (tracker, session, _) = await connected(refusing: ["a"])

        #expect(tracker.refreshCalls == 1)
        // The refused token is sent once; everything after uses the new one.
        #expect(tracker.tokensUsed.first == "a")
        #expect(tracker.tokensUsed.dropFirst().allSatisfy { $0 == "b" })
        #expect(session.identity == alice)
        // Saved, so iCloud carries the new pair to the other devices.
        #expect(tracker.storedTokens == renewed)
        #expect(tracker.credentialChanges == 1)
    }

    @Test func `a refused delivery is refreshed and sent again`() async throws {
        let (tracker, _, queue) = await connected()
        tracker.refusedTokens = ["a"]
        queue.enqueue(.history, .movie(tmdbID: 1), isPresent: true)
        try await waitUntil { !queue.isSyncing }

        #expect(tracker.refreshCalls == 1)
        #expect(tracker.deliveryAttempts == [.movie(tmdbID: 1)])
        #expect(Array(tracker.tokensUsed.suffix(2)) == ["a", "b"])
        #expect(queue.pendingCount == 0)
        #expect(queue.syncError == nil)
    }

    @Test func `an operation token refused at verification is refreshed`() async {
        let (tracker, session, _) = await connected()
        // A new pair arrives from iCloud while offline, so it is unverified
        // and the next scrobble checks whose it is first.
        tracker.storedTokens = FakeTokens(accessToken: "c", refreshToken: "r2", issuedAt: 3)
        tracker.identityResponses = []
        _ = await session.restore()
        tracker.refusedTokens = ["c"]
        tracker.identityResponses = [alice]
        tracker.refreshResponse = .refreshed(FakeTokens(accessToken: "d", refreshToken: "r2", issuedAt: 4))

        #expect(await session.operationAccessToken() == "d")
        #expect(tracker.refreshCalls == 1)
    }

    @Test func `a refused refresh waits for iCloud instead of retrying`() async throws {
        let (tracker, _, queue) = await connected()
        tracker.refusedTokens = ["a"]
        tracker.refreshResponse = .rejected
        queue.enqueue(.history, .movie(tmdbID: 1), isPresent: true)
        try await waitUntil { !queue.isSyncing }
        queue.enqueue(.history, .movie(tmdbID: 2), isPresent: true)
        try await waitUntil { !queue.isSyncing }

        #expect(tracker.refreshCalls == 1)
        #expect(tracker.deliveryAttempts.isEmpty)
        #expect(queue.pendingCount == 2)
        #expect(queue.syncError != nil)
    }

    @Test func `a token refused twice is not refreshed again`() async {
        let (tracker, session, _) = await connected()
        var sent: [String] = []

        await #expect(throws: FakeRefusedTokenError.self) {
            try await session.retryingRefusedToken("a") { token in
                sent.append(token)
                throw FakeRefusedTokenError()
            }
        }
        #expect(sent == ["a", "b"])
        #expect(tracker.refreshCalls == 1)
    }

    @Test func `a refused request cannot retry under a replacement account`() async {
        let (tracker, session, _) = await connected()
        var sent: [String] = []
        await #expect(throws: CancellationError.self) {
            try await session.retryingRefusedToken("a") { token in
                sent.append(token)
                tracker.storedTokens = renewed
                tracker.identityResponses = [bob]
                _ = await session.restore()
                throw FakeRefusedTokenError()
            }
        }
        #expect(sent == ["a"])
        #expect(session.identity == bob)
    }

    @Test func `a refused request survives a verified same account cloud rotation`() async throws {
        let (tracker, session, _) = await connected()
        var sent: [String] = []
        try await session.retryingRefusedToken("a") { token in
            sent.append(token)
            if token == "a" {
                tracker.storedTokens = renewed
                tracker.identityResponses = [alice]
                _ = await session.restore()
                throw FakeRefusedTokenError()
            }
        }
        #expect(sent == ["a", "b"])
        #expect(tracker.refreshCalls == 0)
    }

    @Test func `a refused request cannot cross a disconnect and reconnect to the same account`() async {
        let (tracker, session, _) = await connected()
        var sent: [String] = []
        await #expect(throws: CancellationError.self) {
            try await session.retryingRefusedToken("a") { token in
                sent.append(token)
                await session.disconnect()
                tracker.storedTokens = renewed
                tracker.identityResponses = [alice]
                _ = await session.restore()
                throw FakeRefusedTokenError()
            }
        }
        #expect(sent == ["a"])
    }

    @Test func `a refreshed pair must still identify as the original account before retrying`() async {
        let (tracker, session, _) = await connected()
        tracker.identityResponses = [bob]
        var sent: [String] = []
        await #expect(throws: FakeRefusedTokenError.self) {
            try await session.retryingRefusedToken("a") { token in
                sent.append(token)
                throw FakeRefusedTokenError()
            }
        }
        #expect(sent == ["a"])
        #expect(session.identity == bob)
    }
}
