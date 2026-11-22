import Foundation
@testable import Lume
import Testing

struct StalkerSessionStoreTests {
    @MainActor @Test func `cancelling a waiter releases it without retiring the shared handshake`() async throws {
        let store = StalkerSessionStore()
        let handshakes = Handshakes()
        let started = TaskResult<Void>()
        let release = TaskResult<Void>()
        let handshake: @Sendable () async throws -> StalkerSessionStore.Session = {
            let session = await handshakes.next()
            started.resolve(.success(()))
            try await release.value()
            return session
        }
        var cancelledReturned = false
        let first = Task {
            do {
                _ = try await store.session(for: "key", handshake: handshake)
                Issue.record("A cancelled waiter must not receive a session")
            } catch { #expect(error is CancellationError) }
            cancelledReturned = true
        }
        try await started.value()
        first.cancel()
        try await waitUntil { cancelledReturned }
        #expect(cancelledReturned, "the waiter returns before the handshake is released")
        // With its original waiter gone, a new caller must still join that
        // same handshake, rather than negotiate a token which invalidates it.
        let second = Task { try await store.session(for: "key", handshake: handshake) }
        release.resolve(.success(()))
        await first.value
        #expect(try await second.value.token == "token-1")
        #expect(await handshakes.count == 1)
        #expect(try await store.session(for: "key", handshake: handshake).token == "token-1")
    }

    private actor Handshakes {
        private(set) var count = 0

        func next() -> StalkerSessionStore.Session {
            count += 1
            return StalkerSessionStore.Session(token: "token-\(count)", endpoint: URL(string: "http://portal.test/portal.php")!)
        }
    }

    @Test func `callers arriving during a handshake share it`() async throws {
        let store = StalkerSessionStore()
        let handshakes = Handshakes()
        let handshake: @Sendable () async throws -> StalkerSessionStore.Session = {
            try await Task.sleep(for: .milliseconds(50))
            return await handshakes.next()
        }
        let tokens = try await withThrowingTaskGroup(of: String.self) { group in
            for _ in 0 ..< 8 {
                group.addTask { try await store.session(for: "portal|mac", handshake: handshake).token }
            }
            return try await group.reduce(into: Set<String>()) { $0.insert($1) }
        }
        #expect(tokens == ["token-1"])
        #expect(await handshakes.count == 1)
    }

    @Test func `a refused token is replaced once, not by every caller holding it`() async throws {
        let store = StalkerSessionStore()
        let handshakes = Handshakes()
        let handshake: @Sendable () async throws -> StalkerSessionStore.Session = { await handshakes.next() }
        let first = try await store.session(for: "key", handshake: handshake)

        let fresh = try await store.session(for: "key", rejected: first, handshake: handshake)
        #expect(fresh.token == "token-2")
        // A second caller still holding the old token mustn't discard the new one.
        let again = try await store.session(for: "key", rejected: first, handshake: handshake)
        #expect(again == fresh)
        #expect(await handshakes.count == 2)
    }

    @Test func `a failed handshake isn't cached, so the next caller tries again`() async throws {
        let store = StalkerSessionStore()
        let handshakes = Handshakes()
        await #expect(throws: StalkerError.self) {
            try await store.session(for: "key") { throw StalkerError.handshakeFailed }
        }
        let session = try await store.session(for: "key") { await handshakes.next() }
        #expect(session.token == "token-1")
    }

    @Test func `sessions are kept per portal and device`() async throws {
        let store = StalkerSessionStore()
        let handshakes = Handshakes()
        let handshake: @Sendable () async throws -> StalkerSessionStore.Session = { await handshakes.next() }
        let one = try await store.session(for: "a|mac1", handshake: handshake)
        let two = try await store.session(for: "a|mac2", handshake: handshake)
        #expect(one != two)
        #expect(try await store.session(for: "a|mac1", handshake: handshake) == one)
    }
}
