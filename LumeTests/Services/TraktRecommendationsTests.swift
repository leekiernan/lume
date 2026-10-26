import Foundation
@testable import Lume
import Testing

@Suite(.serialized)
struct TraktRecommendationsTests {
    private func provider(token: String? = "recommendation-token", clientID: String = UUID().uuidString) -> TraktListProvider {
        TraktListProvider(client: TraktClient(session: StubURLProtocol.makeSession(), clientID: clientID, clientSecret: "secret"),
                          accessToken: { token })
    }

    @Test(arguments: SectionSurface.allCases)
    func `each area reads its web recommendation feed in server order`(_ surface: SectionSurface) async throws {
        let source = AuthenticatedHomeList.traktRecommendations.sourceURL(for: surface)
        let url = try #require(URL(string: source))
        let body = switch surface {
        case .home:
            #"[{"show":{"title":"First","ids":{"tmdb":42}},"score":7},{"movie":{"title":"Second","ids":{"tmdb":42}},"score":99}]"#
        case .movies:
            #"[{"movie":{"title":"First","ids":{"tmdb":42}}},{"movie":{"title":"Second","ids":{"tmdb":84}}}]"#
        case .series:
            #"[{"show":{"title":"First","ids":{"tmdb":42}}},{"show":{"title":"Second","ids":{"tmdb":84}}}]"#
        }
        StubURLProtocol.register(host: "api.trakt.tv", path: url.path, response: .init(body: body))
        let clientID = UUID().uuidString
        let page = try await provider(clientID: clientID).page(for: url, number: 1)
        #expect(page.entries.map(\.title) == ["First", "Second"])
        #expect(try page.entries.map(\.mediaType) == (surface == .home ? [.series, .movie] : [#require(surface.mediaType), #require(surface.mediaType)]))
        #expect(page.nextPage == nil)
        let requests = StubURLProtocol.requests(forHost: "api.trakt.tv").filter { $0.value(forHTTPHeaderField: "trakt-api-key") == clientID }
        #expect(requests.count == 1)
        let request = try #require(requests.first)
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer recommendation-token")
        let query = try #require(URLComponents(url: urlFrom(request), resolvingAgainstBaseURL: false)?.queryItems)
        #expect(query.contains(URLQueryItem(name: "limit", value: "100")))
        #expect(query.contains(URLQueryItem(name: "ignore_watched", value: "true")))
        #expect(query.contains(URLQueryItem(name: "ignore_collected", value: "true")))
        // The web client's request: a feed, not a page of a list.
        #expect(!query.contains { $0.name == "page" })
    }

    @Test func `unknown catalogue identities are skipped without reordering or collapsing media namespaces`() async throws {
        let url = try #require(URL(string: AuthenticatedHomeList.traktRecommendations.sourceURL(for: .home)))
        StubURLProtocol.register(host: "api.trakt.tv", path: url.path, response: .init(body: #"[{"movie":{"ids":{"tmdb":3}}},{"movie":{"ids":{}}},{"show":{"ids":{"tmdb":3}}},{"movie":{"ids":{"tmdb":0}}},{}]"#))
        let page = try await provider().page(for: url, number: 1)
        #expect(page.entries.map(\.tmdbId) == [3, 3])
        #expect(page.entries.map(\.mediaType) == [.movie, .series])
    }

    @Test func `a signed out source and invented continuation never make a network request`() async throws {
        let url = try #require(URL(string: AuthenticatedHomeList.traktRecommendations.sourceURL(for: .home)))
        let clientID = UUID().uuidString
        await #expect(throws: HomeListError.accountRequired) {
            try await provider(token: nil, clientID: clientID).page(for: url, number: 1)
        }
        await #expect(throws: HomeListError.invalidURL) {
            try await provider(clientID: clientID).page(for: url, number: 2)
        }
        #expect(!StubURLProtocol.requests(forHost: "api.trakt.tv").contains { $0.value(forHTTPHeaderField: "trakt-api-key") == clientID })
    }

    @Test func `empty recommendations are a successful empty source`() async throws {
        let url = try #require(URL(string: AuthenticatedHomeList.traktRecommendations.sourceURL(for: .home)))
        StubURLProtocol.register(host: "api.trakt.tv", path: url.path, response: .init(body: "[]"))
        let page = try await provider().page(for: url, number: 1)
        #expect(page.entries.isEmpty)
        #expect(page.nextPage == nil)
    }

    @Test func `endpoint and authentication failures are not silently replaced by a different ranking`() async throws {
        let url = try #require(URL(string: AuthenticatedHomeList.traktRecommendations.sourceURL(for: .home)))
        for (status, error) in [(401, HomeListError.accountRequired), (403, .recommendationsUnavailable),
                                (404, .recommendationsUnavailable), (503, .serverError(503))]
        {
            StubURLProtocol.register(host: "api.trakt.tv", path: url.path, response: .init(status: status))
            await #expect(throws: error) { try await provider().page(for: url, number: 1) }
        }
    }

    private func urlFrom(_ request: URLRequest) throws -> URL {
        try #require(request.url)
    }
}
