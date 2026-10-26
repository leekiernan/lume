import Foundation
@testable import Lume
import Testing

struct MediaFavoriteStateTests {
    @Test(arguments: MediaFavoriteDestinationTests.combinations)
    func `one heart combines every list`(bits: Int) {
        let state = MediaFavoriteDestinationTests.state(bits)
        let present = state.local || state.trackers.values.contains(true)
        #expect(state.isFavorite == present)
        #expect(state.toggled == !present)
        for provider in WatchlistProvider.allCases {
            let member = state.trackers[provider] == true
            #expect(state.intent(for: provider) == (!present || member ? !present : nil))
        }
    }

    @Test func `disconnected trackers receive no intent`() {
        for local in [false, true] {
            let state = MediaFavoriteState(local: local)
            #expect(state.isFavorite == local)
            for provider in WatchlistProvider.allCases {
                #expect(state.intent(for: provider) == nil)
            }
            #expect(state.toggleChange.trackers.isEmpty)
        }
    }
}

@MainActor
struct TrackerWatchlistMembershipTests {
    private let movie = TrackerMutation.Target.movie(tmdbID: 1)

    @Test func `a new tap rejects an older snapshot`() {
        let state = TrackerWatchlistMembership()
        state.reset(account: "alice")
        let revision = state.revision
        state.apply(movie, isPresent: true)
        state.replace(with: [], account: "alice", revision: revision)
        #expect(state.contains(movie, account: "alice"))
    }

    @Test func `acknowledgement rejects a read begun before delivery`() {
        let state = TrackerWatchlistMembership()
        state.reset(account: "alice")
        state.apply(movie, isPresent: true)
        let revision = state.revision
        state.invalidate()
        state.replace(with: [], account: "alice", revision: revision)
        #expect(state.contains(movie, account: "alice"))
    }

    @Test func `accounts and reconnects cannot inherit a snapshot`() {
        let state = TrackerWatchlistMembership()
        state.reset(account: "alice")
        let revision = state.revision
        state.apply(movie, isPresent: true)
        #expect(!state.contains(movie, account: "bob"))
        state.reset(account: nil)
        state.reset(account: "alice")
        state.replace(with: [movie], account: "alice", revision: revision)
        #expect(!state.contains(movie, account: "alice"))
        #expect(state.needsRefresh)
    }

    @Test func `a fresh full snapshot accepts unmatched titles and distinguishes movie from show`() {
        let state = TrackerWatchlistMembership()
        state.reset(account: "alice")
        state.replace(with: [movie], account: "alice", revision: state.revision)
        #expect(state.contains(movie, account: "alice"))
        #expect(!state.contains(.show(tmdbID: 1), account: "alice"))
        #expect(!state.needsRefresh)
    }
}
