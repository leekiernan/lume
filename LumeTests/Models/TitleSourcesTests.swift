//
//  TitleSourcesTests.swift
//  LumeTests
//
//  The copies a detail page offers on its Source button: every copy of the
//  title, the opened one included — its own playlist's first, then other
//  playlists' badged with their name — and which copy the page resumes.
//

import Foundation
@testable import Lume
import SwiftData
import Testing

@MainActor
struct TitleSourcesTests {
    private func makePlaylist(name: String, in context: ModelContext) -> Playlist {
        let playlist = Playlist(name: name, serverURL: "http://x.com", username: "u", password: "p")
        context.insert(playlist)
        return playlist
    }

    private func makeMovie(id: String, streamId: Int, tmdbId: Int?, category: String? = nil, in context: ModelContext) -> Movie {
        let movie = Movie(id: id, streamId: streamId, name: "Movie \(streamId)")
        movie.tmdbId = tmdbId
        movie.categoryId = category
        context.insert(movie)
        return movie
    }

    private func makeSeries(id: String, seriesId: Int, tmdbId: Int?, in context: ModelContext) -> Series {
        let series = Series(id: id, seriesId: seriesId, name: "Series \(seriesId)")
        series.tmdbId = tmdbId
        context.insert(series)
        return series
    }

    @Test func `movie copies list the playlist's own first, named by category, then badged other playlists`() throws {
        let container = try makeTestContainer()
        let context = container.mainContext
        let playlistA = makePlaylist(name: "Provider A", in: context)
        let playlistB = makePlaylist(name: "Provider B", in: context)
        let category = Lume.Category(apiId: "9", name: "4K Movies", parentId: 0, type: .vod, playlist: playlistA)
        context.insert(category)

        let current = makeMovie(id: "\(playlistA.id.uuidString)-movie-1", streamId: 1, tmdbId: 42, in: context)
        let uhd = makeMovie(id: "\(playlistA.id.uuidString)-movie-2", streamId: 2, tmdbId: 42, category: category.id, in: context)
        let otherList = makeMovie(id: "\(playlistB.id.uuidString)-movie-3", streamId: 3, tmdbId: 42, in: context)
        _ = makeMovie(id: "\(playlistB.id.uuidString)-movie-4", streamId: 4, tmdbId: 7, in: context)
        try context.save()

        let sources = TitleSources.resolve(for: current, restriction: ContentRestriction(), in: context)
        #expect(Set(sources.prefix(2).map(\.id)) == [current.id, uhd.id])
        #expect(sources.last?.id == otherList.id)
        #expect(sources.last?.playlistName == "Provider B")
        #expect(sources.first { $0.id == uhd.id }?.title == "4K Movies")
    }

    @Test func `series copies badge other playlists with their name`() throws {
        let container = try makeTestContainer()
        let context = container.mainContext
        let playlistA = makePlaylist(name: "Provider A", in: context)
        let playlistB = makePlaylist(name: "Provider B", in: context)
        let current = makeSeries(id: "\(playlistA.id.uuidString)-series-1", seriesId: 1, tmdbId: 314, in: context)
        let otherList = makeSeries(id: "\(playlistB.id.uuidString)-series-2", seriesId: 2, tmdbId: 314, in: context)
        try context.save()

        let sources = TitleSources.resolve(for: current, restriction: ContentRestriction(), in: context)
        #expect(sources.map(\.id) == [current.id, otherList.id])
        #expect(sources.map(\.playlistName) == [nil, "Provider B"])
    }

    @Test func `other playlists sort by name`() throws {
        let container = try makeTestContainer()
        let context = container.mainContext
        let home = makePlaylist(name: "Home", in: context)
        let zeta = makePlaylist(name: "Zeta TV", in: context)
        let alpha = makePlaylist(name: "Alpha IPTV", in: context)
        let current = makeMovie(id: "\(home.id.uuidString)-movie-1", streamId: 1, tmdbId: 42, in: context)
        _ = makeMovie(id: "\(zeta.id.uuidString)-movie-2", streamId: 2, tmdbId: 42, in: context)
        _ = makeMovie(id: "\(alpha.id.uuidString)-movie-3", streamId: 3, tmdbId: 42, in: context)
        try context.save()

        let names = TitleSources.resolve(for: current, restriction: ContentRestriction(), in: context).map(\.playlistName)
        #expect(names == [nil, "Alpha IPTV", "Zeta TV"])
    }

    @Test func `a copy on a playlist that no longer exists is dropped`() throws {
        let container = try makeTestContainer()
        let context = container.mainContext
        let playlist = makePlaylist(name: "Provider A", in: context)
        let current = makeMovie(id: "\(playlist.id.uuidString)-movie-1", streamId: 1, tmdbId: 42, in: context)
        _ = makeMovie(id: "\(UUID().uuidString)-movie-2", streamId: 2, tmdbId: 42, in: context)
        try context.save()

        #expect(TitleSources.resolve(for: current, restriction: ContentRestriction(), in: context).map(\.id) == [current.id])
    }

    @Test func `without a tmdb id the opened copy is the only one`() throws {
        let container = try makeTestContainer()
        let context = container.mainContext
        let playlistA = makePlaylist(name: "Provider A", in: context)
        let playlistB = makePlaylist(name: "Provider B", in: context)
        let current = makeMovie(id: "\(playlistA.id.uuidString)-movie-1", streamId: 1, tmdbId: nil, in: context)
        _ = makeMovie(id: "\(playlistB.id.uuidString)-movie-2", streamId: 2, tmdbId: nil, in: context)
        try context.save()

        #expect(TitleSources.resolve(for: current, restriction: ContentRestriction(), in: context).map(\.id) == [current.id])
    }

    @Test(arguments: [false, true])
    func `hidden copies never appear and restricted copies only appear for parents`(isChild: Bool) async throws {
        let container = try makeTestContainer()
        let context = container.mainContext
        let playlist = makePlaylist(name: "Provider", in: context)
        let opened = makeMovie(id: "\(playlist.id)-movie-1", streamId: 1, tmdbId: 42, in: context)
        let hidden = makeMovie(id: "\(playlist.id)-movie-2", streamId: 2, tmdbId: 42, category: "hidden", in: context)
        let locked = makeMovie(id: "\(playlist.id)-movie-3", streamId: 3, tmdbId: 42, category: "locked", in: context)
        hidden.lastWatchedDate = .now.addingTimeInterval(1)
        locked.lastWatchedDate = .now
        let restriction = ContentRestriction(isActive: isChild, restrictedCategoryIDs: ["locked"], hiddenCategoryIDs: ["hidden"])
        try context.save()

        let sources = TitleSources.resolve(for: opened, restriction: restriction, in: context)
        #expect(Set(sources.map(\.id)) == (isChild ? [opened.id] : [opened.id, locked.id]))
        #expect(TitleSources.preferred(in: sources, opened: opened.id)?.id == (isChild ? opened.id : locked.id))
        let hiddenSource = TitleSource(copy: .movie(hidden), categoryName: nil, playlistName: nil)
        #expect(await TitleSourcePlayback.media(for: hiddenSource, restriction: restriction, in: context) == nil)
    }

    @Test func `a restricted series cannot be resolved or played from a stale menu`() async throws {
        let container = try makeTestContainer()
        let context = container.mainContext
        let playlist = makePlaylist(name: "Provider", in: context)
        let opened = makeSeries(id: "\(playlist.id)-series-1", seriesId: 1, tmdbId: 314, in: context)
        let locked = makeSeries(id: "\(playlist.id)-series-2", seriesId: 2, tmdbId: 314, in: context)
        locked.categoryId = "locked"
        let restriction = ContentRestriction(isActive: true, restrictedCategoryIDs: ["locked"])
        try context.save()

        #expect(TitleSources.resolve(for: opened, restriction: restriction, in: context).map(\.id) == [opened.id])
        let stale = TitleSource(copy: .series(locked), categoryName: nil, playlistName: nil)
        #expect(await TitleSourcePlayback.media(for: stale, restriction: restriction, in: context) == nil)
        opened.categoryId = "locked"
        opened.tmdbId = nil
        #expect(TitleSources.resolve(for: opened, restriction: restriction, in: context).isEmpty)
    }

    /// Each copy keeps its own progress; the page resumes the copy watched
    /// most recently, else the one opened.
    @Test func `the copy watched most recently is preferred, else the one opened`() throws {
        let container = try makeTestContainer()
        let context = container.mainContext
        let playlist = makePlaylist(name: "Provider A", in: context)
        let opened = makeMovie(id: "\(playlist.id.uuidString)-movie-1", streamId: 1, tmdbId: 42, in: context)
        let watched = makeMovie(id: "\(playlist.id.uuidString)-movie-2", streamId: 2, tmdbId: 42, in: context)
        try context.save()

        var sources = TitleSources.resolve(for: opened, restriction: ContentRestriction(), in: context)
        #expect(TitleSources.preferred(in: sources, opened: opened.id)?.id == opened.id)

        watched.lastWatchedDate = .now
        sources = TitleSources.resolve(for: opened, restriction: ContentRestriction(), in: context)
        #expect(TitleSources.preferred(in: sources, opened: opened.id)?.id == watched.id)
    }

    @Test func `runtimes within a minute, or 2% of a long film, are the same cut`() throws {
        let film = try #require(MediaRuntime(seconds: 7200))
        #expect(try film.isSameCut(as: #require(MediaRuntime(seconds: 7255))))
        #expect(try film.isSameCut(as: #require(MediaRuntime(seconds: 7340))))
        #expect(try !film.isSameCut(as: #require(MediaRuntime(seconds: 7600))))
        let episode = try #require(MediaRuntime(seconds: 1500))
        #expect(try !episode.isSameCut(as: #require(MediaRuntime(seconds: 1600))))
    }

    @Test func `a picked copy plays from the page as it is, which becomes that copy once the player closes`() async throws {
        let container = try makeTestContainer()
        let context = container.mainContext
        let playlist = makePlaylist(name: "Provider A", in: context)
        let opened = makeMovie(id: "\(playlist.id.uuidString)-movie-1", streamId: 1, tmdbId: 42, in: context)
        let other = makeMovie(id: "\(playlist.id.uuidString)-movie-2", streamId: 2, tmdbId: 42, in: context)
        try context.save()
        let sources = TitleSources.resolve(for: opened, restriction: ContentRestriction(), in: context)
        let openedSource = try #require(sources.first { $0.id == opened.id })
        let otherSource = try #require(sources.first { $0.id == other.id })
        let selection = TitleSourceSelection(sources: sources, current: openedSource)

        selection.pick(otherSource)
        #expect(selection.current.id == opened.id && selection.picked?.id == other.id)
        let media = await TitleSourcePlayback.media(for: otherSource, restriction: ContentRestriction(), in: context)
        #expect(media?.id == PlayableMedia.from(movie: other, playlist: playlist)?.id)

        selection.showPicked()
        #expect(selection.current.id == other.id && selection.picked == nil)
        // A player closing with no pick (plain Play) changes nothing.
        selection.showPicked()
        #expect(selection.current.id == other.id)

        selection.pick(openedSource)
        selection.abandonPick()
        #expect(selection.current.id == other.id && selection.picked == nil)
    }
}
