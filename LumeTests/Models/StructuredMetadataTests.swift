import Foundation
@testable import Lume
import SwiftData
import Testing

@MainActor
struct StructuredMetadataTests {
    @Test func `normalized values reject invalid units paths and IDs`() throws {
        let details = try TMDBTitleDetails(identity: .series(#require(TMDBSeriesID(1399))), posterPath: "file:///tmp/poster.jpg",
                                           voteAverage: .infinity, runtimeMinutes: Int.max, genreNames: ["", "Drama"],
                                           similarIDs: [0, -1, 1396], imdbId: "123", collectionId: 10)
        #expect(details.artwork.poster == nil && details.score == nil && details.runtime == nil)
        #expect(details.genres.map(\.name) == ["Drama"])
        #expect(try details.similarTitles == [.series(#require(TMDBSeriesID(1396)))])
        #expect(details.imdbIdentifier == nil && details.collection == nil)
    }

    @Test func `classification identity survives storage while provider edits supersede it`() throws {
        let container = try FieldFixtures.makeContainer()
        let context = container.mainContext
        let movie = Movie(id: "structured", streamId: 1, name: "Movie")
        context.insert(movie)
        let genre = try #require(TitleGenre(id: TMDBGenreID(18), name: "Drama"))
        let certification = try #require(TitleCertification(country: CountryCode("GB"), label: "15"))
        movie.genres = [genre]
        movie.certification = certification
        try context.save()

        let reader = ModelContext(container)
        let stored = try #require(reader.fetch(FetchDescriptor<Movie>()).first)
        #expect(stored.genres == [genre] && stored.certification == certification)
        stored.genre = "Comedy"
        stored.contentRating = "PG"
        #expect(stored.genres.first?.id == nil && stored.genres.first?.name == "Comedy")
        #expect(stored.certification?.country == nil && stored.certification?.label == "PG")
    }

    @Test func `a wrong namespace or stale identity cannot update a title`() throws {
        let container = try FieldFixtures.makeContainer()
        let context = container.mainContext
        let movie = Movie(id: "movie", streamId: 1, name: "Movie")
        movie.tmdbId = 603
        context.insert(movie)
        for identity in try [TMDBTitleReference.series(#require(TMDBSeriesID(603))), .movie(#require(TMDBMovieID(604)))] {
            let details = TMDBTitleDetails(identity: identity, posterPath: "/poster.jpg", overview: "Wrong synopsis", voteAverage: 9)
            applyMovieDetails(details, to: movie, context: context)
            #expect(movie.posterPath == nil && movie.plot == nil && movie.rating == 0 && movie.tmdbEnrichedAt == nil)
        }
    }

    @Test func `classification decoders cannot bypass validation`() throws {
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(CountryCode.self, from: Data(#""United Kingdom""#.utf8)) }
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(TitleGenre.self, from: Data(#"{"id":18,"name":" "}"#.utf8)) }
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(TitleCertification.self, from: Data(#"{"country":"GB","label":" "}"#.utf8)) }
    }
}
