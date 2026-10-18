import Foundation
@testable import Lume
import SwiftData
import Testing

/// The watch rails show one card per title, so removing the card has to take
/// every watched copy of that title with it.
@MainActor
@Suite(.globalState, .trackerIdentity(.trakt), .trackerIdentity(.simkl))
struct WatchRailRemovalTests {
    private func movie(_ id: String, tmdbId: Int?, watched: Bool = true, in context: ModelContext) -> Movie {
        let movie = Movie(id: id, streamId: 1, name: "A Film")
        movie.tmdbId = tmdbId
        movie.lastWatchedDate = watched ? .now : nil
        context.insert(movie)
        return movie
    }

    private func series(_ id: String, tmdbId: Int?, in context: ModelContext) -> Series {
        let series = Series(id: id, seriesId: 1, name: "A Show")
        series.tmdbId = tmdbId
        series.lastWatchedDate = .now
        context.insert(series)
        return series
    }

    @Test func `removing a movie unwatches every copy of its title`() throws {
        let context = try ModelContext(makeTestContainer())
        let shown = movie("p1-m-4k", tmdbId: 238, in: context)
        let copy = movie("p1-m-hd", tmdbId: 238, in: context)
        copy.isWatched = true
        let otherPlaylist = movie("p2-m-1", tmdbId: 238, in: context)
        otherPlaylist.watchProgress = 300
        let unrelated = movie("p1-m-other", tmdbId: 240, in: context)
        let tracker = HistorySpy()

        WatchRailRemoval.remove(shown, in: context, trackers: [tracker])

        for unwatched in [shown, copy, otherPlaylist] {
            #expect(unwatched.lastWatchedDate == nil && !unwatched.isWatched && unwatched.watchProgress == 0)
        }
        #expect(unrelated.lastWatchedDate != nil)
        #expect(ContentClearLedger.shared.ids.isSuperset(of: [shown.id, copy.id, otherPlaylist.id]))
        // Once per title: the trackers key it by the TMDB id the copies share.
        #expect(tracker.movieStates == [false])
    }

    /// The bug behind removals reappearing after a restart: the launch's
    /// Trakt paused-playback import put a removed film straight back.
    @Test func `an older Trakt pause cannot return a removed movie`() throws {
        let context = try ModelContext(makeTestContainer())
        let shown = movie("m-1", tmdbId: 100, in: context)
        shown.durationSecs = 600
        shown.watchProgress = 120
        WatchRailRemoval.remove(shown, in: context, trackers: [])

        let ids = TraktWatchedMedia(ids: TraktIDs(tmdb: 100, trakt: nil))
        let pause = TraktPlaybackItem(progress: 50, pausedAt: "2020-01-01T00:00:00Z", movie: ids, show: nil, episode: nil)
        #expect(TraktPlaybackImporter.apply([pause], in: context) == 0)
        #expect(shown.lastWatchedDate == nil)
    }

    /// Without a TMDB id there is no title to match, so only the card goes.
    @Test func `an unmatched movie clears only itself`() throws {
        let context = try ModelContext(makeTestContainer())
        let shown = movie("m-1", tmdbId: nil, in: context)
        let other = movie("m-2", tmdbId: nil, in: context)

        WatchRailRemoval.remove(shown, in: context, trackers: [])

        #expect(shown.lastWatchedDate == nil)
        #expect(other.lastWatchedDate != nil)
    }

    /// TMDB numbers movies and series separately.
    @Test func `removing a series leaves a movie with the same number`() throws {
        let context = try ModelContext(makeTestContainer())
        let shown = series("s-1", tmdbId: 1396, in: context)
        let copy = series("s-2", tmdbId: 1396, in: context)
        let film = movie("m-1", tmdbId: 1396, in: context)

        WatchRailRemoval.remove(shown, in: context)

        #expect(shown.lastWatchedDate == nil)
        #expect(copy.lastWatchedDate == nil)
        #expect(film.lastWatchedDate != nil)
    }

    private final class HistorySpy: TrackerHistorySynchronizing {
        var movieStates: [Bool] = []
        func syncWatched(movie _: Movie, watched: Bool) {
            movieStates.append(watched)
        }

        func syncWatched(episode _: Episode, watched _: Bool) {}

        func retryPendingMutations() {}
    }
}
