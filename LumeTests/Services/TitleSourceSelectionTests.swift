import Foundation
@testable import Lume
import SwiftData
import Testing

@MainActor
struct TitleSourceSelectionTests {
    private func movieSources(in context: ModelContext) -> [TitleSource] {
        (1 ... 3).map { index in
            let movie = Movie(id: "movie-\(index)", streamId: index, name: "Film")
            context.insert(movie)
            return TitleSource(copy: .movie(movie), categoryName: nil, playlistName: nil)
        }
    }

    @Test func `plain Play follows the final source only after dismissal`() throws {
        let container = try makeTestContainer()
        let context = container.mainContext
        let sources = movieSources(in: context)
        let selection = TitleSourceSelection(sources: sources, current: sources[0])
        selection.recordPlayback(.movie(sources[0].id), in: context)
        selection.recordPlayback(.movie(sources[1].id), in: context)
        #expect(selection.current.id == sources[0].id)
        selection.showPicked()
        #expect(selection.current.id == sources[1].id)
        #expect(selection.request == nil)
    }

    @Test func `a picked copy followed by an in-player switch returns to the final copy`() throws {
        let container = try makeTestContainer()
        let context = container.mainContext
        let sources = movieSources(in: context)
        let selection = TitleSourceSelection(sources: sources, current: sources[0])
        selection.pick(sources[1])
        #expect(try selection.beginPlayback(#require(selection.request)))
        // The preparing task is no longer eligible to run when the page returns.
        #expect(selection.request == nil)
        selection.recordPlayback(.movie(sources[2].id), in: context)
        #expect(selection.current.id == sources[0].id)
        selection.showPicked()
        #expect(selection.current.id == sources[2].id)
    }

    @Test func `cancelled and superseded preparation cannot present or abandon a newer pick`() throws {
        let container = try makeTestContainer()
        let sources = movieSources(in: container.mainContext)
        let selection = TitleSourceSelection(sources: sources, current: sources[0])
        selection.pick(sources[1])
        let cancelled = try #require(selection.request)
        selection.abandonPick(cancelled)
        #expect(!selection.beginPlayback(cancelled))
        selection.pick(sources[1])
        let retry = try #require(selection.request)
        #expect(retry.id != cancelled.id)
        selection.abandonPick(cancelled)
        #expect(selection.request?.id == retry.id)
        selection.pick(sources[2])
        let replacement = try #require(selection.request)
        #expect(!selection.beginPlayback(retry))
        selection.abandonPick(retry)
        #expect(selection.beginPlayback(replacement))
        selection.showPicked()
        #expect(selection.current.id == sources[2].id)
    }

    @Test func `an episode switch updates the selected series copy`() throws {
        let container = try makeTestContainer()
        let context = container.mainContext
        let first = Series(id: "first", seriesId: 1, name: "Show")
        let second = Series(id: "second", seriesId: 2, name: "Show")
        context.insert(first)
        context.insert(second)
        let episode = Episode(id: "episode", episodeId: "1", title: "Episode", containerExtension: "mp4", seasonNum: 2, episodeNum: 3, series: second)
        context.insert(episode)
        try context.save()
        let sources = [first, second].map { TitleSource(copy: .series($0), categoryName: nil, playlistName: nil) }
        let selection = TitleSourceSelection(sources: sources, current: sources[0])
        selection.recordPlayback(.episode(episode.id), in: context)
        #expect(selection.current.id == first.id)
        selection.showPicked()
        #expect(selection.current.id == second.id)
    }

    @Test func `unplayed preparation and unrelated media do not replace the detail page`() throws {
        let container = try makeTestContainer()
        let context = container.mainContext
        let sources = movieSources(in: context)
        let selection = TitleSourceSelection(sources: sources, current: sources[0])
        selection.pick(sources[1])
        let request = try #require(selection.request)
        selection.showPicked()
        #expect(selection.current.id == sources[0].id)
        #expect(!selection.beginPlayback(request))
        selection.recordPlayback(.movie("unrelated"), in: context)
        selection.recordPlayback(.live("channel"), in: context)
        selection.showPicked()
        #expect(selection.current.id == sources[0].id)
    }
}
