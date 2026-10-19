import Foundation
@testable import Lume
import Testing

/// Answers `GET /sync/playback` for either tracker and records every request.
private final nonisolated class PlaybackStub: URLProtocol {
    private static let lock = NSLock()
    private nonisolated(unsafe) static var listing = "[]"
    private nonisolated(unsafe) static var missingID: String?
    private nonisolated(unsafe) static var requests: [URLRequest] = []

    static func reset(listing: String, missingID: String? = nil) {
        lock.withLock { Self.listing = listing; Self.missingID = missingID; requests = [] }
    }

    static var recorded: [String] {
        lock.withLock { requests.map { "\($0.httpMethod ?? "") \($0.url?.path ?? "")" } }
    }

    // swiftlint:disable:next static_over_final_class
    override class func canInit(with _: URLRequest) -> Bool {
        true
    }

    // swiftlint:disable:next static_over_final_class
    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        let (listing, missingID) = Self.lock.withLock { () -> (String, String?) in
            Self.requests.append(request)
            return (Self.listing, Self.missingID)
        }
        let isDelete = request.httpMethod == "DELETE"
        let status = isDelete ? (request.url?.lastPathComponent == missingID ? 404 : 204) : 200
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if !isDelete { client?.urlProtocol(self, didLoad: Data(listing.utf8)) }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@MainActor
@Suite(.serialized)
struct PausedProgressRemovalTests {
    private var session: URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [PlaybackStub.self]
        return URLSession(configuration: config)
    }

    private static let episode = TrackerMutation(kind: .playback, target: .episode(showTMDBID: 1396, season: 1, episode: 5), isPresent: false)
    private static let movie = TrackerMutation(kind: .playback, target: .movie(tmdbID: 27205), isPresent: false)

    // MARK: - Trakt

    private static let traktListing = """
    [{"id": 11, "progress": 40, "paused_at": "2026-10-01T00:00:00Z", "type": "episode",
      "episode": {"season": 1, "number": 5}, "show": {"ids": {"tmdb": 1396}}},
     {"id": 12, "progress": 10, "paused_at": "2026-10-02T00:00:00Z", "type": "episode",
      "episode": {"season": 1, "number": 6}, "show": {"ids": {"tmdb": 1396}}},
     {"id": 13, "progress": 75, "paused_at": "2026-10-03T00:00:00Z", "type": "movie", "movie": {"ids": {"tmdb": 27205}}}]
    """

    @Test func `a Trakt removal deletes only the matching paused entry`() async throws {
        PlaybackStub.reset(listing: Self.traktListing)
        let client = TraktClient(session: session, clientID: "test", clientSecret: "test")
        #expect(try await client.apply(Self.episode, accessToken: "token"))
        #expect(PlaybackStub.recorded.filter { $0.hasPrefix("DELETE") } == ["DELETE /sync/playback/11"])
        #expect(!PlaybackStub.recorded.contains { $0.contains("history") })
    }

    @Test func `a Trakt entry already gone counts as removed`() async throws {
        PlaybackStub.reset(listing: Self.traktListing, missingID: "13")
        let client = TraktClient(session: session, clientID: "test", clientSecret: "test")
        #expect(try await client.apply(Self.movie, accessToken: "token"))
        #expect(PlaybackStub.recorded.last == "DELETE /sync/playback/13")
    }

    // MARK: - Simkl

    /// Simkl's documented example: the episode number under `episode`, and
    /// the TMDB id as a string.
    private static let simklListing = """
    [{"id": 123, "progress": 45.5, "paused_at": "2024-01-15T10:30:00.000Z", "type": "episode",
      "episode": {"season": 1, "episode": 5}, "show": {"ids": {"simkl": 12345, "tmdb": "1396"}}},
     {"id": 124, "progress": 75, "paused_at": "2024-01-15T11:15:00.000Z", "type": "movie",
      "movie": {"ids": {"simkl": 67890, "tmdb": "27205"}}}]
    """

    /// The backend sends history changes for every kind but watchlist, so a
    /// paused-progress removal must not fall through to history removal.
    @Test func `a Simkl removal deletes the paused session without touching history`() async throws {
        PlaybackStub.reset(listing: Self.simklListing)
        let backend = SimklAccountBackend(client: SimklClient(session: session, clientID: "test"))
        #expect(try await backend.deliver(Self.episode, accessToken: "token"))
        #expect(PlaybackStub.recorded == ["GET /sync/playback", "DELETE /sync/playback/123"])
    }

    @Test func `a Simkl account with nothing paused gets no deletes`() async throws {
        PlaybackStub.reset(listing: "null")
        let backend = SimklAccountBackend(client: SimklClient(session: session, clientID: "test"))
        #expect(try await backend.deliver(Self.movie, accessToken: "token"))
        #expect(PlaybackStub.recorded == ["GET /sync/playback"])
    }
}
