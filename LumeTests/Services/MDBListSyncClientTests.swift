import Foundation
@testable import Lume
import Testing

// MARK: - Payload shapes

struct MDBListPayloadTests {
    private func json(_ value: some Encodable) throws -> [String: Any] {
        let data = try JSONEncoder().encode(value)
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @Test func `movie history payload carries only the tmdb id`() throws {
        let body = try json(MDBListSyncItems.movie(tmdbID: 272))
        let movies = try #require(body["movies"] as? [[String: Any]])
        #expect(movies.count == 1)
        #expect((movies[0]["ids"] as? [String: Any])?["tmdb"] as? Int == 272)
        #expect(body["shows"] == nil)
    }

    @Test func `episode history payload nests the episode under its season`() throws {
        // A season without an `episodes` array would cascade to every episode
        // in it, so the episode must always be nested.
        let body = try json(MDBListSyncItems.episode(showTMDBID: 1396, season: 2, episode: 3))
        let shows = try #require(body["shows"] as? [[String: Any]])
        let seasons = try #require(shows[0]["seasons"] as? [[String: Any]])
        let episodes = try #require(seasons[0]["episodes"] as? [[String: Any]])
        #expect((shows[0]["ids"] as? [String: Any])?["tmdb"] as? Int == 1396)
        #expect(seasons[0]["number"] as? Int == 2)
        #expect(episodes[0]["number"] as? Int == 3)
        #expect(body["movies"] == nil)
    }

    @Test func `episode scrobble nests season and episode under the show`() throws {
        let body = try json(MDBListScrobbleRequest(target: .episode(showTMDBID: 1668, season: 1, episode: 3), progress: 42.756))
        let show = try #require(body["show"] as? [String: Any])
        let season = try #require(show["season"] as? [String: Any])
        #expect((show["ids"] as? [String: Any])?["tmdb"] as? Int == 1668)
        #expect(season["number"] as? Int == 1)
        #expect((season["episode"] as? [String: Any])?["number"] as? Int == 3)
        #expect(body["progress"] as? Double == 42.76)
        #expect(body["movie"] == nil)
    }

    @Test func `a clear names the title without a progress`() throws {
        let body = try json(MDBListScrobbleRequest(target: .movie(tmdbID: 278)))
        #expect((body["movie"] as? [String: Any]).flatMap { $0["ids"] as? [String: Any] }?["tmdb"] as? Int == 278)
        #expect(body["progress"] == nil)
        #expect(body["app_version"] == nil)
    }

    @Test func `watchlist changes send bare id bags`() throws {
        let movie = try json(#require(MDBListWatchlistMutation(target: .movie(tmdbID: 630))))
        #expect((movie["movies"] as? [[String: Any]])?.first?["tmdb"] as? Int == 630)
        let show = try json(#require(MDBListWatchlistMutation(target: .show(tmdbID: 1396))))
        #expect((show["shows"] as? [[String: Any]])?.first?["tmdb"] as? Int == 1396)
        #expect(MDBListWatchlistMutation(target: .episode(showTMDBID: 1, season: 1, episode: 1)) == nil)
    }

    @Test func `form body percent-encodes values in a stable order`() throws {
        let body = MDBListSyncClient.formBody([
            "scope": "read write",
            "client_id": "abc",
            "grant_type": "urn:ietf:params:oauth:grant-type:device_code"
        ])
        let string = try #require(String(data: body, encoding: .utf8))
        #expect(string == "client_id=abc&grant_type=urn%3Aietf%3Aparams%3Aoauth%3Agrant-type%3Adevice_code&scope=read%20write")
    }
}

// MARK: - Decoding

struct MDBListDecodingTests {
    private func decode<T: Decodable>(_: T.Type, _ json: String) throws -> T {
        try JSONDecoder().decode(T.self, from: Data(json.utf8))
    }

    @Test func `ids decode every tmdb spelling`() throws {
        #expect(try decode(MDBListIDs.self, #"{"tmdb": 272}"#).tmdb == 272)
        #expect(try decode(MDBListIDs.self, #"{"tmdb": "272"}"#).tmdb == 272)
        // The playback responses name it `tmdbid`.
        #expect(try decode(MDBListIDs.self, #"{"tmdbid": 278, "imdbid": "tt0111161"}"#).tmdb == 278)
        #expect(try decode(MDBListIDs.self, #"{"imdb": "tt0372784"}"#).tmdb == nil)
    }

    @Test func `device code falls back to the documented defaults`() throws {
        let code = try decode(MDBListDeviceCode.self, #"{"device_code": "d", "user_code": "ABCD"}"#)
        #expect(code.verificationURL == "https://mdblist.com/oauth/device/")
        #expect(code.expiresIn == 300)
        #expect(code.interval == 5)
    }

    @Test func `a refresh without a new refresh token keeps the old one`() throws {
        let response = try decode(MDBListTokenResponse.self, #"{"access_token": "new", "expires_in": 100}"#)
        let tokens = response.tokens(previousRefreshToken: "kept")
        #expect(tokens.accessToken == "new")
        #expect(tokens.refreshToken == "kept")
        #expect(tokens.expiresIn == 100)
    }

    @Test func `identity scopes by the stable user id`() throws {
        let user = try decode(MDBListUser.self, #"{"user_id": 3, "username": "linas", "name": "Linas"}"#)
        let identity = try #require(MDBListAccountIdentity(user: user))
        #expect(identity.username == "linas")
        #expect(identity.scope == "mdblist:3")

        let noID = try decode(MDBListUser.self, #"{"name": " Linas "}"#)
        #expect(MDBListAccountIdentity(user: noID)?.scope == "username:linas")
        #expect(try MDBListAccountIdentity(user: decode(MDBListUser.self, "{}")) == nil)
    }

    @Test func `playback sessions match by show and episode numbers`() throws {
        let session = try decode(MDBListPlaybackSession.self, """
        {"id": 1, "progress": 68.5, "paused_at": "2025-11-06T19:30:00Z", "type": "episode",
         "movie": null, "episode": {"season": 1, "number": 3, "ids": {"tmdbid": 63174}},
         "show": {"ids": {"tmdbid": 1668}}}
        """)
        #expect(session.matches(.episode(showTMDBID: 1668, season: 1, episode: 3)))
        #expect(!session.matches(.episode(showTMDBID: 1668, season: 1, episode: 4)))
        #expect(!session.matches(.movie(tmdbID: 1668)))
    }

    @Test func `dates parse the iso and spaced forms`() {
        #expect(MDBListDates.parse("2025-10-21T12:00:00Z") != nil)
        #expect(MDBListDates.parse("2025-02-02 17:28:22.000000") != nil)
        #expect(MDBListDates.parse("2025-02-02 17:28:22") != nil)
        #expect(MDBListDates.parse("") == nil)
        #expect(MDBListDates.parse(nil) == nil)
    }
}

// MARK: - History mapping

struct MDBListHistoryMappingTests {
    @Test func `only timestamped rows count as watched, grouped by show`() throws {
        let page = try JSONDecoder().decode(MDBListWatchedHistory.self, from: Data("""
        {"movies": [
            {"last_watched_at": "2025-10-21T12:00:00Z", "movie": {"ids": {"tmdb": 272}}},
            {"last_watched_at": null, "movie": {"ids": {"tmdb": 273}}}
         ],
         "episodes": [
            {"last_watched_at": "2025-10-15T20:00:00Z", "episode": {"season": 1, "number": 1, "show": {"ids": {"tmdb": 1396}}}},
            {"last_watched_at": "2025-10-16T20:00:00Z", "episode": {"season": 1, "number": 2, "show": {"ids": {"tmdb": 1396}}}},
            {"last_watched_at": null, "episode": {"season": 1, "number": 3, "show": {"ids": {"tmdb": 1396}}}},
            {"last_watched_at": "2025-10-17T20:00:00Z", "episode": {"season": 2, "number": 1, "show": {"ids": {"tmdb": 1399}}}}
         ]}
        """.utf8))
        let history = MDBListWatchedImporter.history(page)
        #expect(history.movies.map(\.tmdbID) == [272])
        #expect(history.shows.map(\.tmdbID) == [1396, 1399])
        #expect(Set(history.shows[0].episodes.keys) == [
            TrackerEpisodeKey(season: 1, episode: 1), TrackerEpisodeKey(season: 1, episode: 2)
        ])
    }
}

// MARK: - Client

/// Each test talks to a host of its own, so the shared stub registry can't
/// cross them.
struct MDBListSyncClientTests {
    private func makeClient(host: String) -> MDBListSyncClient {
        MDBListSyncClient(session: StubURLProtocol.makeSession(), clientID: "client", baseURL: "https://\(host)")
    }

    @Test func `is configured requires a client id`() {
        #expect(!MDBListSyncClient(clientID: nil).isConfigured)
        #expect(!MDBListSyncClient(clientID: "").isConfigured)
        #expect(!MDBListSyncClient(clientID: "$(MDBLIST_CLIENT_ID)").isConfigured)
        #expect(MDBListSyncClient(clientID: "id").isConfigured)
    }

    @Test func `watched history follows has more by offset`() async throws {
        let host = "history.mdblist.test"
        StubURLProtocol.register(host: host, query: ("offset", "0"), response: .init(body: """
        {"movies": [{"last_watched_at": "2025-10-21T12:00:00Z", "movie": {"ids": {"tmdb": 1}}}],
         "pagination": {"has_more": true}}
        """))
        StubURLProtocol.register(host: host, query: ("offset", "\(MDBListSyncClient.pageSize)"), response: .init(body: """
        {"movies": [{"last_watched_at": "2025-10-22T12:00:00Z", "movie": {"ids": {"tmdb": 2}}}],
         "pagination": {"has_more": false}}
        """))
        let history = try await makeClient(host: host).watchedHistory(accessToken: "token")
        #expect(history.movies.map(\.movie.ids.tmdb) == [1, 2])
    }

    @Test func `watchlist merges movies and shows newest first`() async throws {
        let host = "watchlist.mdblist.test"
        StubURLProtocol.register(host: host, path: "/watchlist/items", response: .init(body: """
        {"movies": [{"id": 630, "watchlist_at": "2025-02-01 10:00:00.000000"}],
         "shows": [{"id": 1396, "watchlist_at": "2025-02-02 10:00:00.000000"}, {"ids": {}}]}
        """))
        let entries = try await makeClient(host: host).watchlist(accessToken: "token")
        #expect(entries.map(\.target) == [.show(tmdbID: 1396), .movie(tmdbID: 630)])
    }

    @Test func `a pending device code polls as pending`() async {
        let host = "poll.mdblist.test"
        StubURLProtocol.register(host: host, path: "/oauth/token/", response: .init(status: 400, body: #"{"error": "authorization_pending"}"#))
        let backend = await MDBListAccountBackend(client: makeClient(host: host))
        let code = MDBListDeviceCode(deviceCode: "d", userCode: "u", verificationURL: "", verificationURLComplete: nil, expiresIn: 60, interval: 5)
        let outcome = await backend.poll(code)
        guard case .pending = outcome else {
            Issue.record("expected pending, got \(outcome)")
            return
        }
    }

    @Test func `a declined device code ends the connect`() async {
        let host = "declined.mdblist.test"
        StubURLProtocol.register(host: host, path: "/oauth/token/", response: .init(status: 400, body: #"{"error": "access_denied"}"#))
        let backend = await MDBListAccountBackend(client: makeClient(host: host))
        let code = MDBListDeviceCode(deviceCode: "d", userCode: "u", verificationURL: "", verificationURLComplete: nil, expiresIn: 60, interval: 5)
        let outcome = await backend.poll(code)
        guard case .failed(.declined) = outcome else {
            Issue.record("expected declined, got \(outcome)")
            return
        }
    }

    @Test func `a scrobble reply with a decimal-string progress is read`() async throws {
        let host = "scrobble.mdblist.test"
        StubURLProtocol.register(host: host, path: "/scrobble/start", response: .init(status: 201, body: """
        {"id": 12345, "action": "start", "progress": "16.70", "started_at": "2025-11-06T20:00:00Z"}
        """))
        let reply = try await makeClient(host: host).scrobble(.movie(tmdbID: 278), action: .start, progress: 16.7, accessToken: "token")
        #expect(reply?.action == "start")
        #expect(reply?.progress == 16.7)
    }

    /// The status says whether MDBList recorded it; the reply is only logged.
    @Test func `a successful scrobble with an unreadable reply still succeeds`() async throws {
        let host = "scrobble-body.mdblist.test"
        StubURLProtocol.register(host: host, path: "/scrobble/pause", response: .init(body: "OK"))
        let reply = try await makeClient(host: host).scrobble(.movie(tmdbID: 278), action: .pause, progress: 20, accessToken: "token")
        #expect(reply == nil)
    }

    @Test func `clearing a session that is already gone succeeds`() async throws {
        let host = "clear.mdblist.test"
        StubURLProtocol.register(host: host, path: "/scrobble/clear", response: .init(status: 404, body: #"{"error": "Scrobble session not found"}"#))
        try await makeClient(host: host).removePausedProgress(of: .movie(tmdbID: 1), accessToken: "token")
    }

    @Test func `watchlist removal posts to the remove action`() async throws {
        let host = "remove.mdblist.test"
        StubURLProtocol.register(host: host, path: "/watchlist/items/remove", response: .init(body: "{}"))
        let delivered = try await makeClient(host: host).setWatchlist(.show(tmdbID: 1396), watchlisted: false, accessToken: "token")
        #expect(delivered)
        let request = try #require(StubURLProtocol.requests(forHost: host).last)
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer token")
    }

    @Test func `a recovered pause defers to a newer one on mdblist`() async throws {
        let host = "recovered.mdblist.test"
        StubURLProtocol.register(host: host, path: "/sync/playback", response: .init(body: """
        [{"id": 1, "progress": 50, "paused_at": "2030-01-01T00:00:00Z", "type": "movie", "movie": {"ids": {"tmdbid": 278}}}]
        """))
        let pausedAt = try #require(MDBListDates.parse("2025-01-01T00:00:00Z"))
        try await makeClient(host: host).recordPausedProgress(.movie(tmdbID: 278), progress: 20, pausedAt: pausedAt, accessToken: "token")
        #expect(!StubURLProtocol.requests(forHost: host).contains { $0.url?.path == "/scrobble/pause" })
    }
}
