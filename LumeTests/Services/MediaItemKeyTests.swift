import Foundation
@testable import Lume
import Testing

struct MediaItemKeyTests {
    /// Catalog ids are full of dashes (`<playlist UUID>-vod-12`); only the
    /// first one separates the kind.
    @Test func `a key round-trips through its string`() {
        let key = MediaItemKey(kind: .series, id: "\(UUID().uuidString)-series-12")
        #expect(MediaItemKey(key.description) == key)
    }

    @Test func `each kind builds the form the app has always used`() {
        #expect(MediaItemKey.movie("p-vod-1").description == "movie-p-vod-1")
        #expect(MediaItemKey.series("p-series-2").description == "series-p-series-2")
        #expect(MediaItemKey.episode("p-episode-3").description == "episode-p-episode-3")
        #expect(MediaItemKey.live("p-live-4").description == "live-p-live-4")
    }

    @Test func `an unknown kind or a missing separator is no key`() {
        #expect(MediaItemKey("clip-1") == nil)
        #expect(MediaItemKey("movie") == nil)
    }
}

struct CollectionCycleTests {
    @Test func `the next element wraps to the first`() {
        #expect([5, 10, 20].element(after: 5) == 10)
        #expect([5, 10, 20].element(after: 20) == 5)
    }

    /// A stored value no longer offered starts the cycle over.
    @Test func `an element not offered advances to the first`() {
        #expect([5, 10, 20].element(after: 7) == 5)
    }
}
