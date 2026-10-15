import Foundation
@testable import Lume
import Testing

struct TMDBLogoSelectionTests {
    @Test func `unsupported preferred logo does not hide a usable rendition`() async throws {
        StubURLProtocol.register(host: "api.themoviedb.org", path: "/3/movie/987699", response: .init(status: 200, body: #"""
        {"id":987699,"images":{"logos":[
          {"file_path":"/preferred.svg","iso_639_1":"en","vote_average":9},
          {"file_path":"https://example.test/logo.png","iso_639_1":"en","vote_average":8},
          {"file_path":"/usable.png","iso_639_1":"en","vote_average":7}
        ]}}
        """#))
        let client = TMDBClient(session: StubURLProtocol.makeSession(), token: "test-token", language: "en-GB")
        let details = try await client.movieDetails(#require(TMDBMovieID(987_699)))
        #expect(details.artwork.logo?.rawValue == "/usable.png")
    }
}
