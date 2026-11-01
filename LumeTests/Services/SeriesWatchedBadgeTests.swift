import Foundation
@testable import Lume
import SwiftData
import Testing

@MainActor
struct SeriesWatchedBadgeTests {
    private func series(episodes watched: [Bool], in context: ModelContext) -> Series {
        let series = Series(id: UUID().uuidString, seriesId: 1, name: "Show")
        context.insert(series)
        for (index, isWatched) in watched.enumerated() {
            let episode = Episode(
                id: "\(series.id)-\(index)", episodeId: "\(index)", title: "E", containerExtension: "mkv",
                seasonNum: 1, episodeNum: index + 1, series: series
            )
            episode.isWatched = isWatched
            context.insert(episode)
        }
        return series
    }

    @Test func `a series is ticked only when every episode it has is watched`() throws {
        let context = try ModelContext(makeTestContainer())
        let finished = series(episodes: [true, true], in: context)
        let halfway = series(episodes: [true, false], in: context)
        let unopened = series(episodes: [], in: context)
        try context.save()

        #expect(SeriesEpisodeProgress.allEpisodesWatched(seriesID: finished.id, in: context))
        #expect(!SeriesEpisodeProgress.allEpisodesWatched(seriesID: halfway.id, in: context))
        #expect(!SeriesEpisodeProgress.allEpisodesWatched(seriesID: unopened.id, in: context))
    }
}
