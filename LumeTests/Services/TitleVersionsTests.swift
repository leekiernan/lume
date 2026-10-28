//
//  TitleVersionsTests.swift
//  LumeTests
//
//  Watched state follows the title across its versions, while trackers hear
//  about the title once — a change per version would be a play per version
//  on Trakt.
//

import Foundation
@testable import Lume
import SwiftData
import Testing

@MainActor
@Suite(.globalState)
struct TitleVersionsTests {
    private func movie(_ id: String, tmdbId: Int?, in context: ModelContext) -> Movie {
        let movie = Movie(id: id, streamId: 1, name: "Movie")
        movie.tmdbId = tmdbId
        movie.durationSecs = 6000
        context.insert(movie)
        return movie
    }

    private func episode(_ id: String, showTMDB: Int, in context: ModelContext) -> Episode {
        let series = Series(id: "series-\(id)", seriesId: 1, name: "Show")
        series.tmdbId = showTMDB
        context.insert(series)
        let episode = Episode(id: id, episodeId: id, title: "E2", containerExtension: "mkv", seasonNum: 1, episodeNum: 2)
        episode.durationSecs = 600
        episode.series = series
        context.insert(episode)
        return episode
    }

    @Test func `marking a movie watched marks every version and tells each tracker once`() throws {
        let context = try ModelContext(makeTestContainer())
        let fullHD = movie("p1-m-fullHD", tmdbId: 238, in: context)
        let uhd = movie("p1-m-4k", tmdbId: 238, in: context)
        let unrelated = movie("p1-m-other", tmdbId: 240, in: context)
        uhd.watchProgress = 1370
        uhd.lastWatchedDate = .now
        let tracker = HistorySpy()

        MediaWatchState.setWatched(true, movie: fullHD, in: context, trackers: [tracker])

        #expect(fullHD.isWatched && uhd.isWatched)
        #expect(uhd.watchProgress == 6000)
        #expect(!unrelated.isWatched)
        #expect(tracker.movieStates == [true])
    }

    @Test func `unwatching resets every version, once per tracker`() throws {
        let context = try ModelContext(makeTestContainer())
        let fullHD = movie("p1-m-fullHD", tmdbId: 238, in: context)
        let uhd = movie("p1-m-4k", tmdbId: 238, in: context)
        fullHD.setWatched(true)
        uhd.setWatched(true)
        let tracker = HistorySpy()

        MediaWatchState.setWatched(false, movie: uhd, in: context, trackers: [tracker])

        #expect(!fullHD.isWatched && !uhd.isWatched)
        #expect(tracker.movieStates == [false])
        #expect(tracker.clearedMovies == 1)
    }

    @Test func `an episode is marked under every copy of its show`() throws {
        let context = try ModelContext(makeTestContainer())
        let first = episode("p1-e-1", showTMDB: 1396, in: context)
        let second = episode("p1-e-2", showTMDB: 1396, in: context)
        let tracker = HistorySpy()

        MediaWatchState.setWatched(true, episode: first, in: context, trackers: [tracker])

        #expect(first.isWatched && second.isWatched)
        #expect(tracker.episodeStates == [true])
    }

    @Test func `an early exit resets only the version played`() throws {
        let context = try ModelContext(makeTestContainer())
        let fullHD = movie("p1-m-fullHD", tmdbId: 238, in: context)
        let uhd = movie("p1-m-4k", tmdbId: 238, in: context)
        uhd.watchProgress = 1370
        uhd.lastWatchedDate = .now
        fullHD.watchProgress = 3
        fullHD.lastWatchedDate = .now

        #expect(MediaWatchState.discardEarlyProgress(ref: .movie(fullHD.id), position: 3, duration: 6000, in: context, trackers: [HistorySpy()]))

        #expect(fullHD.watchProgress == 0)
        #expect(uhd.watchProgress == 1370)
    }

    @Test func `a movie without a tmdb id stands alone`() throws {
        let context = try ModelContext(makeTestContainer())
        let first = movie("p1-m-a", tmdbId: nil, in: context)
        let second = movie("p1-m-b", tmdbId: nil, in: context)

        MediaWatchState.setWatched(true, movie: first, in: context, trackers: [HistorySpy()])

        #expect(first.isWatched && !second.isWatched)
    }

    /// The case seen on device: a finished version went to Watch Again while
    /// the other kept an old place in Continue Watching.
    @Test func `finishing in the player finishes the other versions, with one change`() async throws {
        let container = try makeTestContainer()
        let setup = ModelContext(container)
        let played = movie("p1-m-fullHD", tmdbId: 238, in: setup)
        let other = movie("p1-m-4k", tmdbId: 238, in: setup)
        other.watchProgress = 1370
        other.lastWatchedDate = .now
        try setup.save()

        let change = await WatchProgressWriter(container: container).record(ref: .movie(played.id), progress: 5600, duration: 6000)

        #expect(change?.isWatched == true)
        let stored = try ModelContext(container).fetch(FetchDescriptor<Movie>())
        let allWatched = stored.allSatisfy(\.isWatched)
        #expect(allWatched)
        #expect(stored.first { $0.id == other.id }?.watchProgress == 6000)
    }

    private final class HistorySpy: TrackerHistorySynchronizing {
        var movieStates: [Bool] = []
        var episodeStates: [Bool] = []
        var clearedMovies = 0
        func syncWatched(movie _: Movie, watched: Bool) {
            movieStates.append(watched)
        }

        func syncWatched(episode _: Episode, watched: Bool) {
            episodeStates.append(watched)
        }

        func clearPausedProgress(movie _: Movie) {
            clearedMovies += 1
        }

        func clearPausedProgress(episode _: Episode) {}

        func recordPausedProgress(movie _: Movie, progress _: Double, pausedAt _: Date) {}

        func recordPausedProgress(episode _: Episode, progress _: Double, pausedAt _: Date) {}

        func retryPendingMutations() {}
    }
}
