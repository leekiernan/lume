import Foundation
@testable import Lume
import SwiftData
import Testing

@MainActor
@Suite(.serialized, .globalState, .trackerIdentity(.mdblist))
struct MDBListWatchedImporterTests {
    init() {
        MDBListPendingWatchedStore.clearAll()
        MDBListPendingWatchedStore.resetCacheForTesting()
        SimklPendingWatchedStore.clearAll()
        SimklPendingWatchedStore.resetCacheForTesting()
    }

    private func history(_ json: String) throws -> MDBListWatchedHistory {
        try JSONDecoder().decode(MDBListWatchedHistory.self, from: Data(json.utf8))
    }

    @Test func `a watched movie is marked with its date`() throws {
        let context = try ModelContext(makeTestContainer())
        let movie = Movie(id: "m", streamId: 1, name: "Batman Begins")
        movie.tmdbId = 272
        movie.durationSecs = 7200
        context.insert(movie)

        let summary = try MDBListWatchedImporter.apply(history("""
        {"movies": [{"last_watched_at": "2025-10-21T12:00:00Z", "movie": {"ids": {"tmdb": 272}}}]}
        """), in: context)

        #expect(summary.moviesMarked == 1)
        #expect(movie.isWatched)
        #expect(movie.lastWatchedDate == MDBListDates.parse("2025-10-21T12:00:00Z"))
    }

    @Test func `episodes of an unopened show are parked in mdblist's own store`() throws {
        let context = try ModelContext(makeTestContainer())
        let series = Series(id: "s", seriesId: 1, name: "Breaking Bad")
        series.tmdbId = 1396
        context.insert(series)

        let summary = try MDBListWatchedImporter.apply(history("""
        {"episodes": [{"last_watched_at": "2025-10-15T20:00:00Z", "episode": {"season": 1, "number": 2, "show": {"ids": {"tmdb": 1396}}}}]}
        """), in: context)

        #expect(summary.showsQueued == 1)
        #expect(MDBListPendingWatchedStore.load()[1396]?.episodes.keys.contains("1x2") == true)
        #expect(SimklPendingWatchedStore.load(scope: .mdblist).isEmpty)
        #expect(series.lastWatchedDate == MDBListDates.parse("2025-10-15T20:00:00Z"))
    }
}
