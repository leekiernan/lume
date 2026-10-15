import Foundation
@testable import Lume
import Testing

@Suite(.serialized)
struct TMDBSearchIdentityTests {
    @Test(arguments: [603, 0, -1])
    func `search results retain endpoint namespace and reject invalid IDs`(_ raw: Int) async throws {
        for path in ["/3/search/movie", "/3/search/tv"] {
            StubURLProtocol.register(host: "api.themoviedb.org", path: path,
                                     response: .init(status: 200, body: "{\"results\":[{\"id\":\(raw)}]}"))
        }
        let client = TMDBClient(session: StubURLProtocol.makeSession(), token: "test-token")
        let movie: TMDBMovieID? = try await client.searchMovieID(query: "Movie")
        let series: TMDBSeriesID? = try await client.searchTVID(query: "Show")
        #expect(movie == TMDBMovieID(raw) && series == TMDBSeriesID(raw))
    }
}
