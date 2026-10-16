import Foundation
@testable import Lume
import SwiftData
import Testing

/// What the player's Source menu offers: another copy only when it can resume
/// at the same moment.
@MainActor
struct PlayerSourceSwitchTests {
    private func playlist(_ context: ModelContext) -> Playlist {
        let playlist = Playlist(name: "Provider", serverURL: "http://x.com", username: "u", password: "p")
        context.insert(playlist)
        return playlist
    }

    private func movie(_ id: Int, runtime: Int?, in playlist: Playlist, _ context: ModelContext) -> Movie {
        let movie = Movie(id: "\(playlist.id.uuidString)-movie-\(id)", streamId: id, name: "Film")
        movie.tmdbId = 42
        movie.durationSecs = runtime
        context.insert(movie)
        return movie
    }

    private func playing(_ movie: Movie, in playlist: Playlist) throws -> PlayableMedia {
        try #require(PlayableMedia.from(movie: movie, playlist: playlist))
    }

    @Test func `a copy of the same cut is offered`() throws {
        // Held: a context outlives its container only as a dangling reference.
        let container = try makeTestContainer()
        let context = container.mainContext
        let provider = playlist(context)
        let current = movie(1, runtime: 7200, in: provider, context)
        let copy = movie(2, runtime: 7230, in: provider, context)
        try context.save()

        let sources = try #require(PlayerSourceSwitch.sources(for: playing(current, in: provider), restriction: ContentRestriction(), in: context))
        #expect(sources.current.id == current.id)
        #expect(sources.alternatives.map(\.source.id) == [copy.id])
    }

    @Test func `a different cut or an unknown runtime is not offered`() throws {
        // Held: a context outlives its container only as a dangling reference.
        let container = try makeTestContainer()
        let context = container.mainContext
        let provider = playlist(context)
        let current = movie(1, runtime: 7200, in: provider, context)
        _ = movie(2, runtime: 8400, in: provider, context)
        _ = movie(3, runtime: nil, in: provider, context)
        try context.save()

        #expect(try PlayerSourceSwitch.sources(for: playing(current, in: provider), restriction: ContentRestriction(), in: context) == nil)
    }

    @Test(arguments: [false, true])
    func `player alternatives apply hidden and parental categories`(isChild: Bool) throws {
        let container = try makeTestContainer()
        let context = container.mainContext
        let provider = playlist(context)
        let current = movie(1, runtime: 7200, in: provider, context)
        let hidden = movie(2, runtime: 7200, in: provider, context)
        let locked = movie(3, runtime: 7200, in: provider, context)
        hidden.categoryId = "hidden"
        locked.categoryId = "locked"
        try context.save()
        let restriction = ContentRestriction(isActive: isChild, restrictedCategoryIDs: ["locked"], hiddenCategoryIDs: ["hidden"])
        let sources = try PlayerSourceSwitch.sources(for: playing(current, in: provider), restriction: restriction, in: context)
        #expect(sources?.alternatives.map(\.source.id) ?? [] == (isChild ? [] : [locked.id]))
    }

    @Test(arguments: [false, true])
    func `TMDB estimates cannot establish the cut of either movie copy`(estimateCurrent: Bool) throws {
        let container = try makeTestContainer()
        let context = container.mainContext
        let provider = playlist(context)
        let current = movie(1, runtime: estimateCurrent ? nil : 7200, in: provider, context)
        let copy = movie(2, runtime: estimateCurrent ? 7200 : nil, in: provider, context)
        let estimated = estimateCurrent ? current : copy
        let details = try TMDBTitleDetails(identity: .movie(#require(TMDBMovieID(42))), runtimeMinutes: 120)
        applyMovieArtwork(details, to: estimated)
        try context.save()

        #expect(estimated.runtime?.seconds == 7200)
        #expect(estimated.streamRuntime == nil)
        #expect(try PlayerSourceSwitch.sources(for: playing(current, in: provider), restriction: ContentRestriction(), in: context) == nil)
        // A provider-supplied duration replacing the estimate becomes evidence.
        estimated.durationSecs = 7230
        #expect(try PlayerSourceSwitch.sources(for: playing(current, in: provider), restriction: ContentRestriction(), in: context)?.alternatives.count == 1)
    }

    @Test func `an episode switches to the same episode in another copy of the series`() throws {
        // Held: a context outlives its container only as a dangling reference.
        let container = try makeTestContainer()
        let context = container.mainContext
        let provider = playlist(context)
        func show(_ id: Int) -> Series {
            let series = Series(id: "\(provider.id.uuidString)-series-\(id)", seriesId: id, name: "Show")
            series.tmdbId = 314
            context.insert(series)
            return series
        }
        func episode(_ id: Int, of series: Series, season: Int, number: Int) -> Episode {
            let episode = Episode(id: "\(provider.id.uuidString)-episode-\(id)", episodeId: "\(id)", title: "Ep",
                                  containerExtension: "mp4", seasonNum: season, episodeNum: number, series: series)
            episode.durationSecs = 2700
            context.insert(episode)
            return episode
        }
        let original = show(1), copy = show(2)
        let watching = episode(10, of: original, season: 2, number: 3)
        _ = episode(20, of: copy, season: 2, number: 2)
        let match = episode(21, of: copy, season: 2, number: 3)
        try context.save()

        let media = try #require(PlayableMedia.from(episode: watching, playlist: provider))
        let sources = try #require(PlayerSourceSwitch.sources(for: media, restriction: ContentRestriction(), in: context))
        #expect(sources.alternatives.map(\.media.contentRef) == [.episode(match.id)])
    }
}
