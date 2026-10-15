import Foundation
@testable import Lume
import Testing

struct MetadataIdentityTests {
    @Test func `identity includes the external namespace`() throws {
        let movie = try #require(TMDBTitleReference(kind: .movie, rawValue: 1))
        let series = try #require(TMDBTitleReference(kind: .series, rawValue: 1))
        #expect(movie != series)
        #expect(TMDBMovieID(0) == nil)
        #expect(TMDBPersonID(-1) == nil)
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(TMDBCollectionID.self, from: Data("0".utf8)) }
        let data = try JSONEncoder().encode(movie)
        #expect(try JSONDecoder().decode(TMDBTitleReference.self, from: data) == movie)
    }

    @Test func `IMDb IDs validate the title namespace and normalize whitespace`() {
        #expect(IMDbTitleID(" TT12345\n")?.rawValue == "tt12345")
        for raw in ["", "nm12345", "tt", "tt123x", "tt123?other=value"] {
            #expect(IMDbTitleID(raw) == nil)
        }
    }
}
