import Foundation
@testable import Lume
import SwiftData
import Testing

@MainActor
struct CatalogueIdentityInvalidationTests {
    private func oldDetails(kind: LumeMetadataKind = .movie) -> TMDBTitleDetails {
        TMDBTitleDetails(identity: TMDBTitleReference(kind: kind, rawValue: 603)!, posterPath: "/old-poster.jpg", backdropPath: "/old-backdrop.jpg", tagline: "Old tagline", overview: "Old synopsis",
                         voteAverage: 8, runtimeMinutes: 90, genreNames: ["Drama"], contentRating: "18",
                         cast: [TMDBCastMember(personID: TMDBPersonID(7)!, name: "Old actor", character: nil, profilePath: nil, order: 0)],
                         similarIDs: [8], videos: [], logoPath: "/old-logo.png", imdbId: "tt0133093",
                         collectionId: 2344, collectionName: "Old collection", collectionPosterPath: "/collection.jpg", collectionBackdropPath: "/collection-backdrop.jpg")
    }

    @Test(arguments: [true, false])
    func `correcting or withdrawing an ID clears old payload and requeues indexing`(_ withdraw: Bool) throws {
        let container = try FieldFixtures.makeContainer()
        let context = container.mainContext
        let movie = Movie(id: "movie", streamId: 1, name: "Movie", streamIcon: "provider-poster")
        context.insert(movie)
        movie.applyCatalogueTMDB("603", previous: nil)
        movie.genre = "Provider genre"
        movie.watchProgress = 123
        movie.isFavorite = true
        movie.localFileURL = "download.mp4"
        applyMovieDetails(oldDetails(), to: movie, context: context)
        movie.externalRatings = try [#require(ExternalRating(source: .imdb, value: 8.0))]
        movie.ratingsEnrichedAt = Date()
        movie.indexedAt = Date()
        movie.embeddingData = Data([1, 2, 3])
        try context.save()

        movie.applyCatalogueTMDB(withdraw ? nil : "604", previous: "603")
        #expect(movie.tmdbId == (withdraw ? nil : 604))
        #expect(movie.posterPath == nil && movie.posterCheckedAt == nil && movie.backdropPath == nil && movie.logoPath == nil)
        #expect(movie.tagline == nil && movie.imdbId == nil && movie.contentRating == nil)
        #expect(movie.collectionId == nil && movie.collectionName == nil && movie.collectionPosterPath == nil && movie.collectionBackdropPath == nil)
        #expect(movie.similarTMDBIds == nil && movie.trailersData == nil && movie.externalRatingsData == nil)
        #expect(movie.tmdbEnrichedAt == nil && movie.tmdbArtworkEnrichedAt == nil && movie.ratingsEnrichedAt == nil)
        #expect(movie.indexedAt == nil && movie.embeddingData == nil)
        #expect(movie.genre == "Provider genre" && movie.plot == nil && movie.durationSecs == nil && movie.rating == 0)
        #expect(movie.streamIcon == "provider-poster" && movie.watchProgress == 123 && movie.isFavorite && movie.localFileURL == "download.mp4")
        #expect(movie.orderedCast.isEmpty && movie.castMembers.count == 1) // Not deleted by background sync.

        // Sparse new metadata cannot accidentally retain a different title's logo,
        // IMDb ID or collection, and scalar-only hydration cannot revive its cast.
        let sparse = try TMDBTitleDetails(identity: .movie(#require(TMDBMovieID(604))), genreNames: [], cast: [], similarIDs: [], videos: [])
        applyMovieArtwork(sparse, to: movie)
        #expect(movie.imdbId == nil && movie.logoPath == nil && movie.collectionId == nil && movie.orderedCast.isEmpty)
        applyMovieDetails(sparse, to: movie, context: context)
        try context.save()
        #expect(!movie.tmdbCastInvalidated && movie.castMembers.isEmpty)
        #expect(try context.fetchCount(FetchDescriptor<CastMember>()) == 0)
    }

    @Test func `series correction keeps provider metadata and episode cache`() throws {
        let container = try FieldFixtures.makeContainer()
        let context = container.mainContext
        let series = Series(id: "series", seriesId: 1, name: "Show", cover: "provider-cover", plot: "Provider synopsis",
                            cast: "Provider cast", genre: "Provider genre", rating: "7")
        context.insert(series)
        series.applyCatalogueTMDB("603", previous: nil)
        series.episodesFetchedAt = Date()
        let episode = Episode(id: "episode", episodeId: "1", title: "Pilot", containerExtension: "mp4", seasonNum: 1, episodeNum: 1)
        context.insert(episode)
        series.episodes.append(episode)
        applySeriesDetails(oldDetails(kind: .series), to: series, context: context)
        series.indexedAt = Date()
        series.embeddingData = Data([1])

        series.applyCatalogueTMDB("604", previous: nil)
        #expect(series.plot == "Provider synopsis" && series.cast == "Provider cast" && series.genre == "Provider genre" && series.rating == "7")
        #expect(series.cover == "provider-cover" && series.episodesFetchedAt != nil && series.episodes.count == 1)
        #expect(series.imdbId == nil && series.logoPath == nil && series.posterPath == nil && series.orderedCast.isEmpty)
        #expect(series.indexedAt == nil && series.embeddingData == nil)
        try applySeriesDetails(TMDBTitleDetails(identity: .series(#require(TMDBSeriesID(604))), genreNames: [], cast: [], similarIDs: [], videos: []), to: series, context: context)
        #expect(!series.tmdbCastInvalidated)
    }

    @Test func `current provider rating wins even when it equals the old TMDB fallback`() throws {
        let container = try FieldFixtures.makeContainer()
        let context = container.mainContext
        let movie = Movie(id: "movie", streamId: 1, name: "Movie")
        context.insert(movie)
        movie.tmdb = "603"
        movie.tmdbId = 603
        applyMovieArtwork(oldDetails(), to: movie)
        #expect(movie.rating == 8)
        let manager = ContentSyncManager(modelContainer: container)
        let dto = try FieldFixtures.decodeMovie(#"{"stream_id":1,"name":"Movie","tmdb":"604","rating":8}"#)
        manager.applyMovieFields(from: dto, to: movie, playlistPrefix: "provider-")
        #expect(movie.tmdbId == 604 && movie.rating == 8)
    }

    /// The reported regression: a panel refreshing new releases sent these
    /// rows with `tmdb`, the poster, rating and trailer blanked. Each copy lost
    /// its identity, artwork and grouping until the panel sent them again.
    @Test func `a blank Xtream tmdb keeps the match its copies share`() throws {
        let container = try FieldFixtures.makeContainer()
        let context = container.mainContext
        let manager = ContentSyncManager(modelContainer: container)
        let standard = Movie(id: "p-movie-10480824", streamId: 10_480_824, name: "Insidious")
        let uhd = Movie(id: "p-movie-10484022", streamId: 10_484_022, name: "4K Insidious")
        for (movie, raw) in [(standard, #""1291595""#), (uhd, "1291595")] {
            context.insert(movie)
            let full = try FieldFixtures.decodeMovie(#"{"stream_id":1,"name":"Insidious","tmdb":\#(raw)}"#)
            manager.applyMovieFields(from: full, to: movie, playlistPrefix: "p-")
            movie.backdropPath = "/backdrop.jpg"
            movie.tmdbEnrichedAt = Date()
            let blank = try FieldFixtures.decodeMovie(#"{"stream_id":1,"name":"Insidious","tmdb":"","stream_icon":"","rating":"0"}"#)
            manager.applyMovieFields(from: blank, to: movie, playlistPrefix: "p-")
            #expect(movie.tmdbId == 1_291_595)
            #expect(movie.backdropPath == "/backdrop.jpg" && movie.tmdbEnrichedAt != nil)
        }
        // A different valid ID still corrects the match.
        try manager.applyMovieFields(from: FieldFixtures.decodeMovie(#"{"stream_id":1,"name":"Insidious","tmdb":"1291596"}"#), to: standard, playlistPrefix: "p-")
        #expect(standard.tmdbId == 1_291_596 && standard.backdropPath == nil)
    }
}
