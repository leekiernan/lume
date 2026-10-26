import Foundation
@testable import Lume
import Testing

/// The heart reads tracker membership from the watchlist read through the
/// shared queue, exercised here through MDBList. A relaunch has nothing in
/// memory: the read, or failing that the last good one, has to make a
/// favourite read as one again.
@MainActor
@Suite(.serialized, .globalState, .trackerIdentity(.mdblist))
struct MDBListWatchlistMembershipTests {
    @Test func `a relaunch reads the watchlist back into membership`() async throws {
        let savedTokens = MDBListTokenStore.load()
        defer {
            if let savedTokens { MDBListTokenStore.save(savedTokens) } else { MDBListTokenStore.clear() }
        }
        let host = "membership.mdblist.test"
        StubURLProtocol.register(host: host, path: "/user", response: .init(body: #"{"user_id": 7, "username": "viewer"}"#))
        StubURLProtocol.register(host: host, path: "/watchlist/items", response: .init(body: """
        {"movies": [{"id": 661539, "mediatype": "movie", "watchlist_at": "2025-02-02 17:28:22.000000"}],
         "shows": [{"id": 1396, "mediatype": "show", "watchlist_at": "2025-02-03 17:28:22.000000"}],
         "pagination": {"has_more": false}}
        """))
        let client = MDBListSyncClient(session: StubURLProtocol.makeSession(), clientID: "client", baseURL: "https://\(host)")
        #expect(MDBListTokenStore.save(.init(accessToken: "token", refreshToken: "refresh", issuedAt: Date.now.timeIntervalSince1970, expiresIn: 2_592_000)))
        let defaultsName = "MDBListWatchlistMembershipTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: defaultsName))
        defer { defaults.removePersistentDomain(forName: defaultsName) }

        let service = MDBListService(client: client, outbox: TrackerMutationOutbox(defaults: defaults, storageKey: "outbox"))
        await service.restore()
        #expect(service.mutations.account == "mdblist:7")
        await service.refreshWatchlistIfNeeded()

        #expect(service.isWatchlisted(.movie(tmdbID: 661_539)))
        #expect(service.isWatchlisted(.show(tmdbID: 1396)))
        #expect(!service.isWatchlisted(.movie(tmdbID: 1396)))
    }

    /// At launch Home asks for the watchlist as soon as the stored tokens make
    /// the account known, while the session is still confirming it.
    @Test func `a watchlist read during the launch restore keeps its membership`() async throws {
        let savedTokens = MDBListTokenStore.load()
        defer {
            if let savedTokens { MDBListTokenStore.save(savedTokens) } else { MDBListTokenStore.clear() }
        }
        let host = "launch.mdblist.test"
        StubURLProtocol.register(host: host, path: "/user", response: .init(body: #"{"user_id": 7, "username": "viewer"}"#))
        StubURLProtocol.register(host: host, path: "/watchlist/items", response: .init(body: """
        {"movies": [{"id": 661539, "mediatype": "movie", "watchlist_at": "2025-02-02 17:28:22.000000"}],
         "pagination": {"has_more": false}}
        """))
        let client = MDBListSyncClient(session: StubURLProtocol.makeSession(), clientID: "client", baseURL: "https://\(host)")
        #expect(MDBListTokenStore.save(.init(accessToken: "token", refreshToken: "refresh", issuedAt: Date.now.timeIntervalSince1970, expiresIn: 2_592_000)))
        MDBListAccountIdentityStore.save(.init(username: "viewer", scope: "mdblist:7"))
        let defaultsName = "MDBListWatchlistMembershipTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: defaultsName))
        defer { defaults.removePersistentDomain(forName: defaultsName) }

        let service = MDBListService(client: client, outbox: TrackerMutationOutbox(defaults: defaults, storageKey: "outbox"))
        let restore = Task { await service.restore() }
        while service.mutations.account == nil {
            await Task.yield()
        }
        let entries = try await service.watchlistEntries()
        await restore.value
        #expect(entries.count == 1)
        #expect(service.isWatchlisted(.movie(tmdbID: 661_539)))
    }

    /// A queued change delivered while Home's first read is in flight retires
    /// that read's snapshot. The refresh that follows must read again rather
    /// than join the retired read, or membership stays empty until something
    /// else asks.
    @Test func `a refresh after a delivery does not join the retired read`() async throws {
        let savedTokens = MDBListTokenStore.load()
        defer {
            if let savedTokens { MDBListTokenStore.save(savedTokens) } else { MDBListTokenStore.clear() }
        }
        let host = "retired.mdblist.test"
        StubURLProtocol.register(host: host, path: "/user", response: .init(body: #"{"user_id": 7, "username": "viewer"}"#))
        StubURLProtocol.register(host: host, path: "/watchlist/items", response: .init(body: """
        {"movies": [{"id": 661539, "mediatype": "movie", "watchlist_at": "2025-02-02 17:28:22.000000"}],
         "pagination": {"has_more": false}}
        """))
        let client = MDBListSyncClient(session: StubURLProtocol.makeSession(), clientID: "client", baseURL: "https://\(host)")
        #expect(MDBListTokenStore.save(.init(accessToken: "token", refreshToken: "refresh", issuedAt: Date.now.timeIntervalSince1970, expiresIn: 2_592_000)))
        let defaultsName = "MDBListWatchlistMembershipTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: defaultsName))
        defer { defaults.removePersistentDomain(forName: defaultsName) }

        let service = MDBListService(client: client, outbox: TrackerMutationOutbox(defaults: defaults, storageKey: "outbox"))
        await service.restore()
        await service.refreshWatchlistIfNeeded()
        let account = try #require(service.mutations.account)
        // A fresh launch's empty membership.
        service.mutations.watchlist.reset(account: nil)
        service.mutations.watchlist.reset(account: account)

        let home = Task { try await service.watchlistEntries() }
        await Task.yield()
        // What a delivered mutation does to the membership.
        service.mutations.watchlist.invalidate()
        await service.refreshWatchlistIfNeeded()
        _ = try await home.value

        #expect(service.isWatchlisted(.movie(tmdbID: 661_539)))
    }

    /// Offline at launch: the read fails, so the last good read — saved by the
    /// previous session — stands in for both the heart and Home's row.
    @Test func `an offline launch keeps the last good read`() async throws {
        let savedTokens = MDBListTokenStore.load()
        defer {
            if let savedTokens { MDBListTokenStore.save(savedTokens) } else { MDBListTokenStore.clear() }
            TrackerWatchlistStore.clear(MDBListAccountBackend.name)
        }
        #expect(MDBListTokenStore.save(.init(accessToken: "token", refreshToken: "refresh", issuedAt: Date.now.timeIntervalSince1970, expiresIn: 2_592_000)))
        MDBListAccountIdentityStore.save(.init(username: "viewer", scope: "mdblist:7"))
        let defaultsName = "MDBListWatchlistMembershipTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: defaultsName))
        defer { defaults.removePersistentDomain(forName: defaultsName) }

        func launch(_ host: String) async -> MDBListService {
            let client = MDBListSyncClient(session: StubURLProtocol.makeSession(), clientID: "client", baseURL: "https://\(host)")
            let service = MDBListService(client: client, outbox: TrackerMutationOutbox(defaults: defaults, storageKey: "outbox"))
            await service.restore()
            return service
        }

        let online = "online.mdblist.test"
        StubURLProtocol.register(host: online, path: "/user", response: .init(body: #"{"user_id": 7, "username": "viewer"}"#))
        StubURLProtocol.register(host: online, path: "/watchlist/items", response: .init(body: """
        {"movies": [{"id": 661539, "mediatype": "movie", "watchlist_at": "2025-02-02 17:28:22.000000"}],
         "pagination": {"has_more": false}}
        """))
        let first = await launch(online)
        _ = try await first.watchlistEntries()

        // Nothing answers on this host: every request fails.
        let offline = await launch("offline.mdblist.test")
        #expect(offline.mutations.account == "mdblist:7")
        // What the heart does as it appears.
        await offline.refreshWatchlistIfNeeded()
        #expect(offline.isWatchlisted(.movie(tmdbID: 661_539)))
        let entries = try await offline.watchlistEntries()
        #expect(entries.map(\.target) == [.movie(tmdbID: 661_539)])
    }
}
