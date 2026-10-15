import Foundation
@testable import Lume
import Testing

struct ArtworkReferenceTests {
    @Test func `paths and remote images cannot be substituted for one another`() throws {
        let path = try #require(TMDBImagePath(" /poster.jpg\n"))
        #expect(TMDBArtworkURL.url(path, size: TMDBPosterSize.w500)?.path == "/t/p/w500/poster.jpg")
        #expect(TMDBImagePath("https://example.test/poster.jpg") == nil)
        #expect(RemoteImageURL("/poster.jpg") == nil)
        #expect(RemoteImageURL("file:///tmp/image.jpg") == nil)
        #expect(RemoteImageURL("https://example.test/image.jpg?token=abc")?.url.query == "token=abc")
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(TMDBImagePath.self, from: Data(#""/folder/image.jpg""#.utf8)) }
    }

    @Test func `all TMDB image builders reject malformed paths`() {
        for raw in ["https://example.test/a.jpg", "//a.jpg", "/a.jpg?x=1", "/a.jpg#x", "/folder/a.jpg", ""] {
            #expect(TMDBClient.backdropURL(raw) == nil)
            #expect(TMDBClient.logoURL(raw) == nil)
            #expect(TMDBClient.profileURL(raw) == nil)
        }
    }
}
