import Foundation
@testable import Lume
import SwiftData
import Testing

@MainActor
struct TMDBFallbackTests {
    @Test func `legacy string provenance maps numeric storage once`() {
        let movie = Movie(id: "legacy", streamId: 1, name: "Movie", rating: 8)
        movie.durationSecs = 5400
        movie.tmdbFallbackData = Data(#"{"rating":{"previous":"0.0","applied":"8.0"},"runtime":{"applied":"5400"}}"#.utf8)
        movie.restoreTMDBFallbacks()
        #expect(movie.rating == 0 && movie.durationSecs == nil)
    }

    @Test func `new numeric provenance is encoded as numbers not display text`() throws {
        let movie = Movie(id: "typed", streamId: 1, name: "Movie")
        movie.recordTMDBFallback(\.runtime, previous: nil, applied: 5400)
        movie.recordTMDBFallback(\.movieRating, previous: 0, applied: 8)
        let data = try #require(movie.tmdbFallbackData)
        let values = try JSONDecoder().decode(TMDBFallbacks.self, from: data)
        #expect(values.runtime?.applied == 5400 && values.movieRating?.applied == 8)
    }

    @Test func `repeated TMDB writes restore original provider genre and absent synopsis`() throws {
        let movie = Movie(id: "movie", streamId: 1, name: "Movie")
        movie.genre = "Provider genre"
        try applyMovieArtwork(TMDBTitleDetails(identity: .movie(#require(TMDBMovieID(603))), overview: "TMDB synopsis", voteAverage: 8, runtimeMinutes: 90, genreNames: ["Drama"],
                                               cast: [], similarIDs: [], videos: []), to: movie)
        try applyMovieArtwork(TMDBTitleDetails(identity: .movie(#require(TMDBMovieID(603))), genreNames: ["Comedy"], cast: [], similarIDs: [], videos: []), to: movie)
        #expect(movie.genre == "Comedy" && movie.durationSecs == 5400 && movie.rating == 8)

        movie.restoreTMDBFallbacks()
        #expect(movie.genre == "Provider genre" && movie.plot == nil)
        #expect(movie.durationSecs == nil && movie.rating == 0 && movie.tmdbFallbackData == nil)
    }

    @Test func `provider edits after hydration survive restoration`() throws {
        let series = Series(id: "series", seriesId: 1, name: "Show")
        let details = try TMDBTitleDetails(identity: .series(#require(TMDBSeriesID(603))), overview: "TMDB synopsis", voteAverage: 8, genreNames: ["Drama"],
                                           cast: [TMDBCastMember(personID: #require(TMDBPersonID(7)), name: "Actor", character: nil, profilePath: nil, order: 0)],
                                           similarIDs: [], videos: [])
        applySeriesArtwork(details, to: series)
        series.plot = "Provider edit"
        series.rating = "9"
        series.restoreTMDBFallbacks()
        #expect(series.plot == "Provider edit" && series.rating == "9")
        #expect(series.genre == nil && series.cast == nil)
    }

    @Test func `fallback provenance persists across contexts`() throws {
        let container = try FieldFixtures.makeContainer()
        let movie = Movie(id: "movie", streamId: 1, name: "Movie")
        container.mainContext.insert(movie)
        movie.genre = "Provider genre"
        try applyMovieArtwork(TMDBTitleDetails(identity: .movie(#require(TMDBMovieID(603))), genreNames: ["Drama"], cast: [], similarIDs: [], videos: []), to: movie)
        try container.mainContext.save()
        let reloaded = try #require(ModelContext(container).fetch(FetchDescriptor<Movie>()).first)
        reloaded.restoreTMDBFallbacks()
        #expect(reloaded.genre == "Provider genre")
    }

    @Test func `legacy shared metadata without provenance is preserved`() {
        let movie = Movie(id: "legacy", streamId: 1, name: "Movie", rating: 7)
        movie.plot = "Unknown source"
        movie.genre = "Unknown source"
        movie.durationSecs = 5400
        movie.restoreTMDBFallbacks()
        #expect(movie.plot == "Unknown source" && movie.genre == "Unknown source")
        #expect(movie.durationSecs == 5400 && movie.rating == 7)
    }
}
