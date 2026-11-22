import Foundation
@testable import Lume
import Testing

struct StalkerSessionStoreTests {
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
