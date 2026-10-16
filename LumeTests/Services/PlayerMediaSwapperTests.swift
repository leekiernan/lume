import Foundation
@testable import Lume
import Testing

@MainActor
struct PlayerMediaSwapperTests {
    private func media(_ id: String) throws -> PlayableMedia {
        try PlayableMedia(id: id, url: #require(URL(string: "https://example.com/\(id).mp4")), title: id, subtitle: nil,
                          posterURL: nil, kind: .vod, startTime: 1200, contentRef: .episode(id))
    }

    @Test func `source and transport changes share one cooldown without completing the source`() throws {
        var time = Date(timeIntervalSince1970: 100)
        let swapper = PlayerMediaSwapper(now: { time })
        let copy = try media("copy"), next = try media("next")
        let neighbours = PlayerItemNavigation.Neighbours(axis: .episode, next: next)
        var selected: [PlayableMedia] = []
        var completed = 0
        #expect(swapper.source(copy) { selected.append($0) })
        #expect(!swapper.step(.next, in: neighbours, onCompleteCurrentItem: { completed += 1 }, select: { selected.append($0) }))
        #expect(selected == [copy] && completed == 0)
        time = time.addingTimeInterval(PlayerMediaSwapper.cooldown + 0.01)
        #expect(swapper.step(.next, in: neighbours, onCompleteCurrentItem: { completed += 1 }, select: { selected.append($0) }))
        #expect(!swapper.source(copy) { selected.append($0) })
        #expect(selected == [copy, next] && completed == 1)
        time = time.addingTimeInterval(PlayerMediaSwapper.cooldown + 0.01)
        #expect(swapper.source(copy) { selected.append($0) })
        #expect(selected.last?.startTime == 1200 && completed == 1)
    }

    @Test func `an unavailable neighbour does not consume the source cooldown`() throws {
        let swapper = PlayerMediaSwapper(now: { Date(timeIntervalSince1970: 100) })
        let copy = try media("copy")
        var selected: PlayableMedia?
        #expect(!swapper.step(.next, in: .none) { selected = $0 })
        #expect(swapper.source(copy) { selected = $0 })
        #expect(selected == copy)
    }
}
