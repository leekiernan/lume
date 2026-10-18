import Foundation
@testable import Lume
import SwiftData
import Testing

/// The watch rails show one card per title, so removing the card has to take
/// every watched copy of that title with it.
@MainActor
@Suite(.globalState)
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

    @Test func `removing a movie clears every watched copy of its title`() throws {
        let context = try ModelContext(makeTestContainer())
        let shown = movie("p1-m-4k", tmdbId: 238, in: context)
        let copy = movie("p1-m-hd", tmdbId: 238, in: context)
        let otherPlaylist = movie("p2-m-1", tmdbId: 238, in: context)
        let unrelated = movie("p1-m-other", tmdbId: 240, in: context)

        WatchRailRemoval.remove(shown, in: context)

        #expect([shown, copy, otherPlaylist].allSatisfy { $0.lastWatchedDate == nil })
        #expect(unrelated.lastWatchedDate != nil)
        #expect(ContentClearLedger.shared.ids.isSuperset(of: [shown.id, copy.id, otherPlaylist.id]))
    }

    /// Without a TMDB id there is no title to match, so only the card goes.
    @Test func `an unmatched movie clears only itself`() throws {
        let context = try ModelContext(makeTestContainer())
        let shown = movie("m-1", tmdbId: nil, in: context)
        let other = movie("m-2", tmdbId: nil, in: context)

        WatchRailRemoval.remove(shown, in: context)

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
}
