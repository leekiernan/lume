import Foundation
@testable import Lume
import Testing

@MainActor
struct DetailPosterArtworkTests {
    @Test func `live logos never request TMDB poster recovery`() {
        let stream = LiveStream(id: "channel", streamId: 1, name: "Channel")
        stream.streamIcon = "https://provider.test/logo.png"
        let item = HomeMediaItem.live(stream)
        #expect(item.posterPath == nil)
        #expect(item.posterRecoveryRequest == nil)
        #expect(item.imageURL?.absoluteString == stream.streamIcon)
    }

    /// Similar-title cards (`MediaItemCell`) recover a broken provider image
    /// from the stored TMDB poster, scoped to the item's own category.
    @Test func `movie cards retain fallback recovery scope`() {
        let movie = Movie(id: "playlist-movie-1", streamId: 1, name: "Movie")
        movie.streamIcon = "https://provider.test/broken.jpg"
        movie.posterPath = "/stored.jpg"
        movie.categoryId = "restricted-category"
        let item = HomeMediaItem.movie(movie)
        #expect(item.posterRecoveryRequest == PosterArtworkRequest(kind: .movie, id: movie.id, categoryID: movie.categoryId))
        let source = PosterArtworkSource(provider: item.imageURL?.absoluteString, posterPath: item.posterPath)
        #expect(source.primaryURL == item.imageURL)
        #expect(source.url(afterPrimaryFailure: true)?.path == "/t/p/w500/stored.jpg")
    }

    @Test func `series cards without provider artwork use their stored poster`() {
        let series = Series(id: "playlist-series-1", seriesId: 1, name: "Series")
        series.posterPath = "/series.jpg"
        let item = HomeMediaItem.series(series)
        #expect(item.posterRecoveryRequest?.kind == .series)
        #expect(item.posterRecoveryRequest?.id == series.id)
        #expect(PosterArtworkSource(provider: item.imageURL?.absoluteString, posterPath: item.posterPath).primaryURL?.path == "/t/p/w500/series.jpg")
    }
}
