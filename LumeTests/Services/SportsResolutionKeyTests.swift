import Foundation
@testable import Lume
import Testing

@MainActor
struct SportsResolutionKeyTests {
    @Test func `a landed playlist sync re-keys the resolve`() {
        let playlist = Playlist(name: "Proxy", serverURL: "http://proxy.test", username: "u", password: "p")
        let before = SportsFixtureResolutionMachine.catalogToken(for: [playlist])
        let key = { SportsFixtureResolutionMachine.requestKey(for: [], visibilityToken: "v", guideRevision: 3, catalogToken: $0) }
        #expect(key(before) == key(SportsFixtureResolutionMachine.catalogToken(for: [playlist])))
        // Providers rename event channels as a match nears; the sync that
        // brings them must prompt a fresh pass on a surface left open.
        playlist.lastSyncDate = Date(timeIntervalSince1970: 1_791_633_600)
        #expect(key(before) != key(SportsFixtureResolutionMachine.catalogToken(for: [playlist])))
    }

    @Test func `the token ignores playlist order`() {
        let first = Playlist(name: "A", serverURL: "http://a.test", username: "", password: "")
        let second = Playlist(name: "B", serverURL: "http://b.test", username: "", password: "")
        #expect(SportsFixtureResolutionMachine.catalogToken(for: [first, second])
            == SportsFixtureResolutionMachine.catalogToken(for: [second, first]))
    }
}
