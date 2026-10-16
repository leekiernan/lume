import Foundation
@testable import Lume
import SwiftData
import Testing

/// Source discovery is independent of runtime; duration evidence only decides
/// whether carrying the playhead requires a restart confirmation.
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

    @Test func `different cuts and unknown runtimes remain visible`() throws {
        // Held: a context outlives its container only as a dangling reference.
        let container = try makeTestContainer()
        let context = container.mainContext
        let provider = playlist(context)
        let current = movie(1, runtime: 7200, in: provider, context)
        let different = movie(2, runtime: 8400, in: provider, context)
        let unknown = movie(3, runtime: nil, in: provider, context)
        try context.save()

        let sources = try #require(PlayerSourceSwitch.sources(for: playing(current, in: provider), restriction: ContentRestriction(), in: context))
        #expect(Set(sources.alternatives.map(\.source.id)) == [different.id, unknown.id])
        for option in sources.alternatives {
            let warning = PlayerSourceSwitch.requiresRestart(current: sources.currentRuntime, alternative: option.runtime, measuredDuration: 0)
            #expect(warning == (option.source.id == different.id))
        }
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
    func `TMDB estimates neither hide copies nor create mismatch warnings`(estimateCurrent: Bool) throws {
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
        let sources = try #require(PlayerSourceSwitch.sources(for: playing(current, in: provider), restriction: ContentRestriction(), in: context))
        let option = try #require(sources.alternatives.first)
        #expect(option.source.id == copy.id)
        #expect(!PlayerSourceSwitch.requiresRestart(current: sources.currentRuntime, alternative: option.runtime, measuredDuration: 0))
        // A provider-supplied duration replacing the estimate becomes evidence.
        estimated.durationSecs = 7230
        #expect(try PlayerSourceSwitch.sources(for: playing(current, in: provider), restriction: ContentRestriction(), in: context)?.alternatives.count == 1)
    }

    @Test func `copies with no file duration at all still appear and resume at the current position`() throws {
        let container = try makeTestContainer()
        let context = container.mainContext
        let provider = playlist(context)
        let current = movie(1, runtime: nil, in: provider, context)
        let copy = movie(2, runtime: nil, in: provider, context)
        copy.watchProgress = 400
        try context.save()
        let sources = try #require(PlayerSourceSwitch.sources(for: playing(current, in: provider), restriction: ContentRestriction(), in: context))
        let option = try #require(sources.alternatives.first)
        #expect(sources.currentRuntime == nil && option.runtime == nil)
        #expect(!PlayerSourceSwitch.requiresRestart(current: nil, alternative: nil, measuredDuration: 7200))
        #expect(PlayerSourceSwitch.media(for: option, start: .currentPosition, position: 1800).startTime == 1800)
        #expect(PlayerSourceSwitch.media(for: option, start: .beginning, position: 1800).startTime == 0)
        #expect(copy.watchProgress == 400)
    }

    @Test func `player measured duration overrides stored duration when checking for a mismatch`() throws {
        let same = try #require(MediaRuntime(seconds: 7200))
        let different = try #require(MediaRuntime(seconds: 8400))
        #expect(!PlayerSourceSwitch.requiresRestart(current: different, alternative: same, measuredDuration: 7200))
        #expect(PlayerSourceSwitch.requiresRestart(current: different, alternative: different, measuredDuration: 7200))
        #expect(PlayerSourceSwitch.requiresRestart(current: nil, alternative: different, measuredDuration: 7200))
        #expect(PlayerSourceSwitch.requiresRestart(current: same, alternative: different, measuredDuration: .nan))
        #expect(!PlayerSourceSwitch.requiresRestart(current: nil, alternative: different, measuredDuration: .infinity))
    }

    @Test func `no matching identity still hides the player source menu`() throws {
        let container = try makeTestContainer()
        let context = container.mainContext
        let provider = playlist(context)
        let current = movie(1, runtime: nil, in: provider, context)
        let other = movie(2, runtime: nil, in: provider, context)
        other.tmdbId = 99
        try context.save()
        #expect(try PlayerSourceSwitch.sources(for: playing(current, in: provider), restriction: ContentRestriction(), in: context) == nil)
    }

    @Test func `provider detail durations replace estimates without adding requests`() async throws {
        let container = try makeTestContainer()
        let context = container.mainContext
        let provider = playlist(context)
        let host = "\(UUID().uuidString.lowercased()).example"
        provider.serverURL = "https://\(host)"
        let current = movie(1, runtime: nil, in: provider, context)
        let copy = movie(2, runtime: nil, in: provider, context)
        let estimate = try TMDBTitleDetails(identity: .movie(#require(TMDBMovieID(42))), runtimeMinutes: 120)
        applyMovieArtwork(estimate, to: current)
        applyMovieArtwork(estimate, to: copy)
        for (id, duration) in [(1, 7200), (2, 8400)] {
            StubURLProtocol.register(host: host, query: ("vod_id", String(id)), response: .init(body: "{\"info\":{\"duration_secs\":\(duration)}}"))
        }
        try context.save()
        let loader = StreamDetailsLoader(client: XtreamClient(urlSession: StubURLProtocol.makeSession()))
        let copies = TitleSources.resolve(for: current, restriction: ContentRestriction(), in: context)
        await loader.load(copies, in: context)
        let sources = try #require(PlayerSourceSwitch.sources(for: playing(current, in: provider), restriction: ContentRestriction(), in: context))
        let option = try #require(sources.alternatives.first)
        #expect(sources.currentRuntime?.seconds == 7200 && option.runtime?.seconds == 8400)
        #expect(PlayerSourceSwitch.requiresRestart(current: sources.currentRuntime, alternative: option.runtime, measuredDuration: 7200))
        await loader.load(copies, in: context)
        #expect(StubURLProtocol.requests(forHost: host).count == 2)
    }

    @Test func `delayed confirmations cannot switch another stream or a newly hidden copy`() throws {
        let container = try makeTestContainer()
        let context = container.mainContext
        let provider = playlist(context)
        let current = movie(1, runtime: 7200, in: provider, context)
        let copy = movie(2, runtime: 8400, in: provider, context)
        copy.categoryId = "optional"
        try context.save()
        let media = try playing(current, in: provider)
        let sources = try #require(PlayerSourceSwitch.sources(for: media, restriction: ContentRestriction(), in: context))
        let option = try #require(sources.alternatives.first)
        let request = PlayerSourceSwitch.Request(originID: media.id, targetID: option.id)
        #expect(request.target(in: sources, playingID: media.id)?.id == option.id)
        #expect(request.target(in: sources, playingID: "another-stream") == nil)
        let restricted = PlayerSourceSwitch.sources(for: media, restriction: ContentRestriction(hiddenCategoryIDs: ["optional"]), in: context)
        #expect(request.target(in: restricted, playingID: media.id) == nil)
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
        watching.durationSecs = nil
        match.durationSecs = nil
        let unknown = try #require(PlayerSourceSwitch.sources(for: media, restriction: ContentRestriction(), in: context))
        #expect(unknown.alternatives.map(\.media.contentRef) == [.episode(match.id)])
    }
}
