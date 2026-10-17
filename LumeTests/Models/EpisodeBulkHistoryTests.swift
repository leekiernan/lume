import Foundation
@testable import Lume
import SwiftData
import Testing

@MainActor
@Suite(.globalState)
struct EpisodeBulkHistoryTests {
    @Test func `bulk actions retain ordering progress and series recency`() throws {
        let container = try makeTestContainer()
        let context = container.mainContext
        let show = Series(id: UUID().uuidString, seriesId: 1, name: "Show")
        context.insert(show)
        let episodes = (1 ... 4).map { number in
            let episode = Episode(
                id: "\(show.id)-\(number)", episodeId: "\(number)", title: "Episode",
                containerExtension: "mp4", seasonNum: 1, episodeNum: number, series: show
            )
            episode.durationSecs = 1800
            context.insert(episode)
            return episode
        }
        try context.save()
        episodes[2].markEarlierEpisodesWatched()
        #expect(episodes.prefix(2).allSatisfy { $0.isWatched && $0.watchProgress == 1800 })
        #expect(!episodes[2].isWatched && !episodes[3].isWatched)
        #expect(show.lastWatchedDate == episodes.prefix(2).compactMap(\.lastWatchedDate).max())

        episodes[3].setWatched(true)
        episodes[0].markLaterEpisodesUnwatched()
        #expect(episodes.dropFirst().allSatisfy { !$0.isWatched && $0.watchProgress == 0 && $0.lastWatchedDate == nil })
        #expect(show.lastWatchedDate == episodes[0].lastWatchedDate)
        #expect(RecentResumePoints.position(for: .episode(episodes[3].id), stored: 99, storedAt: nil) == 0)
        episodes[0].setWatched(false)
        #expect(show.lastWatchedDate == nil)
    }
}
