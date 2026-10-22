import Foundation
@testable import Lume
import SwiftData
import Testing

/// The watch rails show one card per title, so removing the card unwatches
/// what it stands for on every copy — and on linked trackers.
@MainActor
@Suite(.globalState, .trackerIdentity(.trakt), .trackerIdentity(.simkl))
struct WatchRailRemovalTests {
    private func movie(_ id: String, tmdbId: Int?, in context: ModelContext) -> Movie {
        let movie = Movie(id: id, streamId: 1, name: "A Film")
        movie.tmdbId = tmdbId
        movie.lastWatchedDate = .now
        context.insert(movie)
        return movie
    }

    // MARK: - Movies

    /// Clearing an unfinished film forgets it was started; it doesn't unwatch it.
    @Test func `continue watching clears every copy's progress and keeps history`() throws {
        let context = try ModelContext(makeTestContainer())
        let shown = movie("p1-m-4k", tmdbId: 238, in: context)
        shown.watchProgress = 120
        let otherPlaylist = movie("p2-m-1", tmdbId: 238, in: context)
        otherPlaylist.watchProgress = 300
        let finished = movie("p1-m-hd", tmdbId: 238, in: context)
        finished.isWatched = true
        let unrelated = movie("p1-m-other", tmdbId: 240, in: context)
        let tracker = HistorySpy()

        WatchRailRemoval.removeFromContinueWatching(shown, in: context, trackers: [tracker])

        for cleared in [shown, otherPlaylist] {
            #expect(cleared.lastWatchedDate == nil && cleared.watchProgress == 0 && !cleared.isWatched)
        }
        #expect(finished.isWatched && finished.lastWatchedDate != nil)
        #expect(unrelated.lastWatchedDate != nil)
        #expect(ContentClearLedger.shared.ids.isSuperset(of: [shown.id, otherPlaylist.id]))
        // Only the paused place, once per title: no history change.
        #expect(tracker.events == ["movie paused cleared"])
    }

    @Test func `recently watched unwatches every copy of its title`() throws {
        let context = try ModelContext(makeTestContainer())
        let shown = movie("p1-m-4k", tmdbId: 238, in: context)
        shown.isWatched = true
        let copy = movie("p1-m-hd", tmdbId: 238, in: context)
        copy.isWatched = true
        let tracker = HistorySpy()

        WatchRailRemoval.removeFromRecentlyWatched(shown, in: context, trackers: [tracker])

        for unwatched in [shown, copy] {
            #expect(unwatched.lastWatchedDate == nil && !unwatched.isWatched && unwatched.watchProgress == 0)
        }
        #expect(tracker.events == ["movie watched false", "movie paused cleared"])
    }

    /// Without a TMDB id there is no title to match, so only the card goes.
    @Test func `an unmatched movie clears only itself`() throws {
        let context = try ModelContext(makeTestContainer())
        let shown = movie("m-1", tmdbId: nil, in: context)
        let other = movie("m-2", tmdbId: nil, in: context)

        WatchRailRemoval.removeFromContinueWatching(shown, in: context, trackers: [])

        #expect(shown.lastWatchedDate == nil)
        #expect(other.lastWatchedDate != nil)
    }

    // MARK: - Series

    /// S1 E1–2 watched, E3 part-way: the card shows E3.
    private func series(_ id: String, in context: ModelContext) -> (Series, [Episode]) {
        let series = Series(id: id, seriesId: 1, name: "A Show")
        series.tmdbId = 1396
        context.insert(series)
        let episodes = (1 ... 3).map { number in
            let episode = Episode(
                id: "\(id)-e\(number)", episodeId: "\(number)", title: "E\(number)", containerExtension: "mkv",
                seasonNum: 1, episodeNum: number, series: series
            )
            episode.durationSecs = 600
            episode.isWatched = number < 3
            episode.watchProgress = number < 3 ? 600 : 120
            episode.lastWatchedDate = Date(timeIntervalSinceNow: Double(number - 10) * 60)
            context.insert(episode)
            return episode
        }
        series.lastWatchedDate = episodes[2].lastWatchedDate
        return (series, episodes)
    }

    private func continuation(_ episode: Int) -> SeriesContinuation {
        SeriesContinuation(season: 1, episode: episode, fraction: nil, remaining: nil)
    }

    @Test func `continue watching clears only the episode a series shows`() throws {
        let context = try ModelContext(makeTestContainer())
        let (shown, episodes) = series("p1-s", in: context)
        let (copy, copyEpisodes) = series("p2-s", in: context)
        let tracker = HistorySpy()

        WatchRailRemoval.removeFromContinueWatching(shown, continuing: continuation(3), in: context, trackers: [tracker])

        for episode in [episodes[2], copyEpisodes[2]] {
            #expect(!episode.isWatched && episode.watchProgress == 0 && episode.lastWatchedDate == nil)
        }
        #expect(episodes[0].isWatched && episodes[1].isWatched)
        // Earlier episodes keep it on the rail, now at the start of E3.
        #expect(shown.lastWatchedDate == episodes[1].lastWatchedDate)
        #expect(copy.lastWatchedDate != nil)
        #expect(tracker.events == ["episode 3 paused cleared"])
    }

    /// A card on an episode not yet started has nothing to unwatch: that
    /// removal takes the series off the rails.
    @Test func `removing a series on an unstarted episode takes it off the rails`() throws {
        let context = try ModelContext(makeTestContainer())
        let (shown, episodes) = series("s", in: context)
        let tracker = HistorySpy()

        WatchRailRemoval.removeFromContinueWatching(shown, continuing: continuation(4), in: context, trackers: [tracker])

        #expect(shown.lastWatchedDate == nil)
        #expect(episodes[2].watchProgress == 120)
        #expect(tracker.events.isEmpty)
    }

    /// TMDB numbers movies and series separately.
    @Test func `removing a series leaves a movie with the same number`() throws {
        let context = try ModelContext(makeTestContainer())
        let (shown, _) = series("s", in: context)
        let film = movie("m-1", tmdbId: 1396, in: context)

        WatchRailRemoval.removeFromContinueWatching(shown, continuing: continuation(3), in: context, trackers: [])

        #expect(film.lastWatchedDate != nil)
    }

    private final class HistorySpy: TrackerHistorySynchronizing {
        var events: [String] = []
        func syncWatched(movie _: Movie, watched: Bool) {
            events.append("movie watched \(watched)")
        }

        func syncWatched(episode: Episode, watched: Bool) {
            events.append("episode \(episode.episodeNum) watched \(watched)")
        }

        func clearPausedProgress(movie _: Movie) {
            events.append("movie paused cleared")
        }

        func clearPausedProgress(episode: Episode) {
            events.append("episode \(episode.episodeNum) paused cleared")
        }

        func recordPausedProgress(movie _: Movie, progress _: Double, pausedAt _: Date) {}

        func recordPausedProgress(episode _: Episode, progress _: Double, pausedAt _: Date) {}

        func retryPendingMutations() {}
    }
}
