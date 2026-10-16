import Foundation
@testable import Lume
import Testing

struct HomeListPagingTests {
    @Test func `TMDB rail reads one page and retains continuation`() async throws {
        let path = "/3/list/970001"
        StubURLProtocol.register(host: "api.themoviedb.org", path: path, response: .init(body: """
        {"total_pages":5,"items":[{"id":603,"media_type":"movie","title":"The Matrix"}]}
        """))
        let provider = TMDBListProvider(client: TMDBClient(session: StubURLProtocol.makeSession(), token: "test"))
        let url = try #require(URL(string: "https://themoviedb.org/list/970001"))
        let page = try await provider.page(for: url, number: 1)
        #expect(page.entries.map(\.tmdbId) == [603])
        #expect(page.nextPage == 2)
        let requests = StubURLProtocol.requests(forHost: "api.themoviedb.org").filter { $0.url?.path == path }
        #expect(requests.count == 1)
        #expect(requests.first?.url?.query?.contains("page=1") == true)
    }

    @Test func `trakt rail requests twenty entries not the whole collection`() async throws {
        let path = "/users/paging-test/lists/rail/items"
        StubURLProtocol.register(host: "api.trakt.tv", path: path, response: .init(body: """
        [{"type":"show","show":{"title":"A Show","ids":{"tmdb":1399}}}]
        """, headers: ["X-Pagination-Page-Count": "3"]))
        let client = TraktClient(session: StubURLProtocol.makeSession(), clientID: "test", clientSecret: "test")
        let page = try await client.listPage(apiPath: "users/paging-test/lists/rail/items", accessToken: nil, number: 1)
        #expect(page.entries.map(\.tmdbId) == [1399])
        #expect(page.entries.first?.mediaType == .series)
        #expect(page.nextPage == 2)
        let requests = StubURLProtocol.requests(forHost: "api.trakt.tv").filter { $0.url?.path == path }
        #expect(requests.count == 1)
        #expect(requests.first?.url?.query?.contains("limit=20") == true)
    }

    @Test func `TMDB sparse terminal page and provider page cap have no continuation`() async throws {
        StubURLProtocol.register(host: "api.themoviedb.org", path: "/3/list/970002", response: .init(body: """
        {"total_pages":99,"items":[]}
        """))
        let client = TMDBClient(session: StubURLProtocol.makeSession(), token: "test")
        let page = try await client.listPage(apiPath: "list/970002", media: nil, number: 5)
        #expect(page.nextPage == nil)
        #expect(page.entries.isEmpty)
    }
}
