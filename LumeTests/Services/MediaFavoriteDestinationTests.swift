@testable import Lume
import Testing

struct MediaFavoriteDestinationTests {
    /// Every combination of local and tracker membership, one bit each.
    static let combinations = 0 ..< 1 << (WatchlistProvider.allCases.count + 1)

    static func state(_ bits: Int) -> MediaFavoriteState {
        var trackers: [WatchlistProvider: Bool] = [:]
        for (index, provider) in WatchlistProvider.allCases.enumerated() {
            trackers[provider] = bits & (2 << index) != 0
        }
        return MediaFavoriteState(local: bits & 1 != 0, trackers: trackers)
    }

    @Test(arguments: combinations, MediaFavoriteState.Destination.allCases)
    func `individual changes affect only the selected destination`(bits: Int, destination: MediaFavoriteState.Destination) throws {
        let state = Self.state(bits)
        for isPresent in [false, true] {
            let change = try #require(state.change(setting: isPresent, in: destination))
            #expect(change.local == (destination == .local ? isPresent : nil))
            for provider in WatchlistProvider.allCases {
                #expect(change.trackers[provider] == (destination == .tracker(provider) ? isPresent : nil))
            }
        }
    }

    @Test func `unavailable services cannot be changed`() {
        let state = MediaFavoriteState(local: true)
        for isPresent in [false, true] {
            for provider in WatchlistProvider.allCases {
                #expect(state.change(setting: isPresent, in: .tracker(provider)) == nil)
            }
            #expect(state.change(setting: isPresent, in: .local) == .init(local: isPresent))
        }
    }

    @Test(arguments: combinations)
    func `normal press still synchronizes the combined membership`(bits: Int) {
        let state = Self.state(bits)
        let change = state.toggleChange
        let present = state.isFavorite
        #expect(change.local == !present)
        for provider in WatchlistProvider.allCases {
            let expected = !present || state.trackers[provider] == true ? !present : nil
            #expect(change.trackers[provider] == expected)
        }
    }

    @Test(arguments: WatchlistProvider.allCases)
    func `one remaining remote membership keeps the heart filled`(provider: WatchlistProvider) {
        var trackers = Dictionary(uniqueKeysWithValues: WatchlistProvider.allCases.map { ($0, false) })
        #expect(!MediaFavoriteState(local: false, trackers: trackers).isFavorite)
        trackers[provider] = true
        #expect(MediaFavoriteState(local: false, trackers: trackers).isFavorite)
    }
}
