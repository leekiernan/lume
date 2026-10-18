import Foundation
@testable import Lume
import Testing

@MainActor
struct LibraryCollectionReadTests {
    @Test func `timing reads once and preserves model identity and order`() {
        let first = Movie(id: "first", streamId: 1, name: "First")
        let second = Movie(id: "second", streamId: 2, name: "Second")
        var calls = 0
        let result = LibraryCollectionRead.measure(.recentlyAdded, media: .movie) {
            calls += 1
            return [second, first]
        }
        #expect(calls == 1)
        #expect(result.count == 2)
        #expect(result[0] === second)
        #expect(result[1] === first)
    }

    @Test func `each local rail has a distinct stable marker`() {
        let kinds: [LibraryCollection.Kind] = [.continueWatching, .recentlyWatched, .favorites, .recentlyAdded]
        let movie = kinds.map { LibraryCollectionRead.signpost($0, media: .movie).metricName }
        let series = kinds.map { LibraryCollectionRead.signpost($0, media: .series).metricName }
        #expect(movie == ["LibraryMovieContinueRead", "LibraryMovieWatchedRead", "LibraryMovieFavoritesRead", "LibraryMovieAddedRead"])
        #expect(series == ["LibrarySeriesContinueRead", "LibrarySeriesWatchedRead", "LibrarySeriesFavoritesRead", "LibrarySeriesAddedRead"])
        #expect(Set(movie + series).count == 8)
    }
}
