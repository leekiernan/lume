import Foundation
@testable import Lume
import SwiftData
import Testing

@MainActor
struct ProxyMetadataApplicationTests {
    private func fixture() throws -> (ModelContainer, Playlist, Movie, TMDBTitleDetails) {
        let container = try FieldFixtures.makeContainer()
        let context = container.mainContext
        let playlist = Playlist(name: "Proxy", serverURL: "https://metadata.example.com/panel", username: "user", password: "password")
        let movie = Movie(id: "\(playlist.id.uuidString)-movie-1", streamId: 1, name: "Movie")
        movie.tmdbId = 603
        context.insert(playlist)
        context.insert(movie)
        let source = try #require(LumeProxySource(playlist: playlist))
        let receipt = LumeMetadataReceipt(sourceIdentity: source.identity, tmdbID: 603, language: "en-GB",
                                          tmdbAt: Date().addingTimeInterval(-7200), artworkAt: Date().addingTimeInterval(-3600))
        let details = TMDBTitleDetails(identity: .movie(TMDBMovieID(603)!), proxyReceipt: receipt, posterPath: "/poster.jpg", overview: "Synopsis", genreNames: ["Drama"],
                                       cast: [TMDBCastMember(personID: TMDBPersonID(7)!, name: "Actor", character: nil, profilePath: nil, order: 0)],
                                       similarIDs: [8], videos: [])
        return (container, playlist, movie, details)
    }

    @Test func `scalar publication persists original age but never full cast or ratings completion`() throws {
        let (container, _, movie, details) = try fixture()
        let context = container.mainContext
        movie.externalRatings = try [#require(ExternalRating(source: .imdb, value: 8.0))]
        applyMovieArtwork(details, to: movie)
        try context.save()
        let reloaded = try #require(ModelContext(container).fetch(FetchDescriptor<Movie>()).first)
        #expect(reloaded.posterPath == "/poster.jpg")
        #expect(reloaded.proxyMetadataData != nil)
        #expect(reloaded.tmdbArtworkEnrichedAt == details.proxyReceipt?.artworkAt)
        #expect(reloaded.posterCheckedAt == details.proxyReceipt?.artworkAt)
        #expect(reloaded.tmdbEnrichedAt == nil && reloaded.castMembers.isEmpty)
        #expect(reloaded.ratingsEnrichedAt == nil && reloaded.externalRatings.first?.value == "8.0/10")
        #expect(!movie.hasFreshTMDBDetails(in: context, language: "en-GB"))
        #expect(movie.hasFreshTMDBArtwork(in: context, language: "en-GB"))
    }

    /// Render paths resolve the owner's source from playlists they already
    /// hold instead of fetching it per title; the answer must not change.
    @Test(arguments: ["unchanged", "account", "endpoint", "tmdb"])
    func `an in-memory source map gives the same artwork freshness as a fetch`(_ edit: String) throws {
        let (container, playlist, movie, details) = try fixture()
        let context = container.mainContext
        applyMovieArtwork(details, to: movie)
        try context.save()
        switch edit {
        case "account": playlist.username = "new-account"
        case "endpoint": playlist.serverURL = "https://ordinary.example.com"
        case "tmdb": movie.tmdbId = 604
        default: break
        }
        let sources = LumeProxySource.snapshots(of: [playlist])
        let source = LumeProxySource.snapshot(contentID: movie.id, from: sources)
        // At the receipts' own language, so a fresh receipt is really tested.
        #expect(movie.hasFreshTMDBArtwork(source: source, language: "en-GB") == movie.hasFreshTMDBArtwork(in: context, language: "en-GB"))
        #expect(movie.hasFreshTMDBArtwork(source: source, language: "en-GB") == (edit == "unchanged"))
        let mapped = movie.effectiveTMDBArtworkDate(source: source)
        #expect(mapped == movie.effectiveTMDBArtworkDate)
        // A title whose playlist is not in the map has no source, as when
        // its owner can't be fetched.
        #expect(movie.effectiveTMDBArtworkDate(source: LumeProxySource.snapshot(contentID: movie.id, from: [:])) == nil)
    }

    @Test func `full detail publication keeps both source ages and cast`() throws {
        let (container, _, movie, details) = try fixture()
        let context = container.mainContext
        applyMovieDetails(details, to: movie, context: context)
        try context.save()
        #expect(movie.tmdbEnrichedAt == details.proxyReceipt?.tmdbAt)
        #expect(movie.tmdbArtworkEnrichedAt == details.proxyReceipt?.artworkAt)
        #expect(movie.castMembers.map(\.name) == ["Actor"])
        #expect(movie.hasFreshTMDBDetails(in: context, language: "en-GB"))
        #expect(!movie.hasFreshTMDBDetails(in: context, language: "de-DE"))
    }

    @Test(arguments: ["account", "endpoint", "tmdb"])
    func `edited identity cannot reuse local proxy completion`(_ field: String) throws {
        let (container, playlist, movie, details) = try fixture()
        let context = container.mainContext
        applyMovieDetails(details, to: movie, context: context)
        try context.save()
        switch field {
        case "account": playlist.username = "new-account"
        case "endpoint": playlist.serverURL = "https://ordinary.example.com"
        default: movie.tmdbId = 604
        }
        #expect(!movie.hasFreshTMDBDetails(in: context, language: "en-GB"))
        #expect(!movie.hasFreshTMDBArtwork(in: context, language: "en-GB"))
        #expect(movie.posterPath == "/poster.jpg") // Keep useful data; discard proof.
    }

    @Test func `new scalar pass cannot renew older full detail proof`() throws {
        let (container, _, movie, details) = try fixture()
        let context = container.mainContext
        applyMovieDetails(details, to: movie, context: context)
        var newer = details
        let previous = try #require(details.proxyReceipt)
        newer.proxyReceipt = LumeMetadataReceipt(sourceIdentity: previous.sourceIdentity, tmdbID: 603, language: "en-GB",
                                                 tmdbAt: Date(), artworkAt: Date())
        applyMovieArtwork(newer, to: movie)
        #expect(movie.tmdbEnrichedAt == previous.tmdbAt)
        #expect(movie.tmdbArtworkEnrichedAt == newer.proxyReceipt?.artworkAt)
        #expect(movie.castMembers.map(\.name) == ["Actor"])
    }

    @Test func `device scalar fetch clears only artwork provenance`() throws {
        let (container, playlist, movie, details) = try fixture()
        let context = container.mainContext
        applyMovieDetails(details, to: movie, context: context)
        var device = details
        device.proxyReceipt = nil
        applyMovieArtwork(device, to: movie)
        playlist.password = "new-password"
        #expect(!movie.hasFreshTMDBDetails(in: context, language: "en-GB"))
        #expect(movie.hasFreshTMDBArtwork(in: context, language: "en-GB"))
        applyMovieDetails(device, to: movie, context: context)
        #expect(movie.proxyMetadataData == nil)
        #expect(movie.hasFreshTMDBDetails(in: context, language: "en-GB"))
    }

    @Test func `provider identity replacement clears completion without erasing user state`() throws {
        let (container, playlist, movie, details) = try fixture()
        let context = container.mainContext
        movie.watchProgress = 123
        movie.isFavorite = true
        applyMovieDetails(details, to: movie, context: context)
        try context.save()
        let manager = ContentSyncManager(modelContainer: container)
        let dto = try FieldFixtures.decodeMovie(#"{"stream_id":1,"name":"Movie","tmdb":"604"}"#)
        manager.applyMovieFields(from: dto, to: movie, playlistPrefix: "\(playlist.id.uuidString)-vod-")
        #expect(movie.tmdbId == 604)
        #expect(movie.proxyMetadataData == nil)
        #expect(movie.tmdbEnrichedAt == nil && movie.tmdbArtworkEnrichedAt == nil)
        #expect(movie.watchProgress == 123 && movie.isFavorite)
    }

    @Test func `provider plot replacement invalidates series proof but sparse metadata does not`() throws {
        let (container, playlist, _, details) = try fixture()
        let context = container.mainContext
        let series = Series(id: "\(playlist.id.uuidString)-series-1", seriesId: 1, name: "Series")
        series.tmdbId = 603
        context.insert(series)
        applySeriesDetails(details, to: series, context: context)
        let data = series.proxyMetadataData
        try series.applyProviderMetadata(FieldFixtures.decodeSeries(#"{"series_id":1,"plot":""}"#), fillMissing: false)
        #expect(series.proxyMetadataData == data)
        try series.applyProviderMetadata(FieldFixtures.decodeSeries(#"{"series_id":1,"plot":"Provider synopsis"}"#), fillMissing: false)
        #expect(series.plot == "Provider synopsis")
        #expect(series.proxyMetadataData == nil && series.tmdbEnrichedAt == nil)
    }

    @Test func `future local markers are not considered fresh`() {
        #expect(!TMDBFreshness.isFresh(Date().addingTimeInterval(3600)))
        #expect(!LumeMetadataReceipt.isFresh(nil))
    }
}
