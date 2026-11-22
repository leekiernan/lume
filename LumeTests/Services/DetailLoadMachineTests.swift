import Foundation
@testable import Lume
import SwiftData
import Testing

@MainActor
struct DetailLoadMachineTests {
    @Test func `a collection is filtered before replacement tasks and restored from cached ids`() async throws {
        let context = try ModelContext(makeTestContainer())
        let movie = Movie(id: "movie", streamId: 1, name: "Movie")
        movie.tmdbId = 1
        movie.collectionId = 10
        movie.similarTitleIds = [2]
        let part = Movie(id: "part", streamId: 2, name: "Part")
        part.tmdbId = 2
        part.categoryId = "hidden"
        context.insert(movie)
        context.insert(part)
        try context.save()
        var reads = 0
        let loader = MovieDetailLoadMachine(movie: movie, fetchCollection: { _, _ in reads += 1; return [2] })
        loader.resolveSimilar(movie, in: context)
        await loader.loadCollection(movie, in: context)
        #expect(loader.snapshot(for: movie).collectionMovies == [.movie(part)])
        let hidden = ContentRestriction(hiddenCategoryIDs: ["hidden"])
        #expect(loader.snapshot(for: movie, restriction: hidden).collectionMovies.isEmpty)
        #expect(loader.snapshot(for: movie, restriction: hidden).similar.isEmpty)
        loader.restrict(hidden, movie: movie, in: context)
        #expect(loader.collectionMovies.isEmpty)
        loader.restrict(ContentRestriction(), movie: movie, in: context)
        #expect(loader.collectionMovies == [.movie(part)])
        #expect(reads == 1)
    }

    @Test func `a visibility change retires an in flight collection response`() async throws {
        let context = try ModelContext(makeTestContainer())
        let movie = Movie(id: "movie", streamId: 1, name: "Movie")
        movie.collectionId = 10
        context.insert(movie)
        var resume: CheckedContinuation<[Int], Never>?
        let loader = MovieDetailLoadMachine(movie: movie, fetchCollection: { _, _ in
            await withCheckedContinuation { resume = $0 }
        })
        let pending = Task { await loader.loadCollection(movie, in: context) }
        try await waitUntil { resume != nil }
        loader.restrict(ContentRestriction(hiddenCategoryIDs: ["hidden"]), movie: movie, in: context)
        resume?.resume(returning: [2])
        await pending.value
        #expect(loader.snapshot(for: movie).collectionOutcome == nil)
        #expect(loader.collectionMovies.isEmpty)
    }

    @Test func `episode failures differ from successful empty results and retry without stale errors`() async throws {
        let context = try ModelContext(makeTestContainer())
        let series = Series(id: "series", seriesId: 1, name: "Series")
        let playlist = Playlist(name: "P", serverURL: "https://example.invalid", username: "u", password: "p")
        context.insert(series)
        var reads = 0
        let loader = SeriesDetailLoadMachine(series: series, fetchEpisodes: { _, _, _, _ in
            reads += 1
            if reads == 1 { throw URLError(.cannotConnectToHost) }
            return FetchedEpisodes(episodes: [])
        })
        await loader.loadEpisodes(series, playlist: playlist, in: context)
        #expect(loader.snapshot(for: series).episodeOutcome == .failed)
        #expect(series.episodesFetchedAt == nil)
        await loader.loadEpisodes(series, playlist: playlist, in: context)
        #expect(loader.snapshot(for: series).episodeOutcome == .loaded)
        #expect(series.episodesFetchedAt != nil)
    }

    @Test func `collection failure retains cached content but is distinct from an empty collection`() async throws {
        let context = try ModelContext(makeTestContainer())
        let movie = Movie(id: "movie", streamId: 1, name: "Movie")
        movie.collectionId = 10
        context.insert(movie)
        let part = Movie(id: "part", streamId: 2, name: "Part")
        part.tmdbId = 2
        context.insert(part)
        try context.save()
        var reads = 0
        let loader = MovieDetailLoadMachine(movie: movie, fetchCollection: { _, _ in
            reads += 1
            if reads == 2 { throw URLError(.cannotConnectToHost) }
            return reads == 1 ? [2] : []
        })
        await loader.loadCollection(movie, in: context)
        #expect(loader.snapshot(for: movie).collectionMovies == [.movie(part)])
        await loader.loadCollection(movie, in: context)
        #expect(loader.snapshot(for: movie).collectionOutcome == .failed)
        #expect(loader.snapshot(for: movie).collectionMovies == [.movie(part)])
        await loader.loadCollection(movie, in: context)
        #expect(loader.snapshot(for: movie).collectionOutcome == .loaded)
        #expect(loader.snapshot(for: movie).collectionMovies.isEmpty)
    }

    private func episode(_ number: Int, season: Int, series: Series) -> Episode {
        Episode(id: "\(series.id)-\(season)-\(number)", episodeId: "\(number)", title: "Episode",
                containerExtension: "mp4", seasonNum: season, episodeNum: number, series: series)
    }

    @Test func `series projection orders episodes and preserves a valid user selected season`() {
        let series = Series(id: "series", seriesId: 1, name: "Series")
        series.episodes = [episode(3, season: 2, series: series), episode(1, season: 1, series: series),
                           episode(1, season: 2, series: series)]
        let machine = SeriesDetailLoadMachine(series: series)
        machine.recomputeSeasons(series)
        machine.selectedSeason = 2
        series.episodes.append(episode(2, season: 2, series: series))
        machine.recomputeSeasons(series)
        #expect(machine.availableSeasons == [1, 2])
        #expect(machine.episodesBySeason[2]?.map(\.episodeNum) == [1, 2, 3])
        #expect(machine.selectedSeason == 2)
    }

    @Test func `series projection repairs a removed selected season and resets for another title`() {
        let series = Series(id: "first", seriesId: 1, name: "First")
        series.episodes = [episode(1, season: 2, series: series)]
        let machine = SeriesDetailLoadMachine(series: series)
        machine.recomputeSeasons(series)
        #expect(machine.selectedSeason == 2)
        let replacement = Series(id: "second", seriesId: 2, name: "Second")
        machine.recomputeSeasons(replacement)
        #expect(machine.contentID == replacement.id)
        #expect(machine.availableSeasons.isEmpty)
        #expect(machine.episodesBySeason.isEmpty)
        #expect(machine.selectedSeason == 1)
    }

    @Test func `initial series load picks furthest progress without requiring a playlist`() async throws {
        let container = try makeTestContainer()
        let context = ModelContext(container)
        let series = Series(id: "series", seriesId: 1, name: "Series")
        let first = episode(1, season: 1, series: series)
        let later = episode(2, season: 3, series: series)
        later.watchProgress = 60
        series.episodes = [first, later]
        context.insert(series)
        let machine = SeriesDetailLoadMachine(series: series)
        await machine.load(series, playlist: nil, in: context)
        #expect(machine.selectedSeason == 3)
        #expect(!machine.isLoadingTMDB)
        #expect(!machine.isLoadingEpisodes)
        machine.selectedSeason = 1
        await machine.refreshEpisodesIfStale(series, playlist: nil, in: context)
        #expect(machine.selectedSeason == 1)
    }

    @Test func `episode retry without a playlist settles without stamping freshness`() async throws {
        let container = try makeTestContainer()
        let context = ModelContext(container)
        let series = Series(id: "series", seriesId: 1, name: "Series")
        context.insert(series)
        let machine = SeriesDetailLoadMachine(series: series)
        await machine.loadEpisodes(series, playlist: nil, in: context)
        #expect(!machine.isLoadingEpisodes)
        #expect(series.episodes.isEmpty)
        #expect(series.episodesFetchedAt == nil)
    }

    @Test func `movie load without metadata settles and collection removal clears the lane`() async throws {
        let container = try makeTestContainer()
        let context = ModelContext(container)
        let movie = Movie(id: "movie", streamId: 1, name: "Movie")
        context.insert(movie)
        let machine = MovieDetailLoadMachine(movie: movie)
        await machine.load(movie, in: context)
        await machine.loadCollection(movie, in: context)
        #expect(!machine.isLoadingTMDB)
        #expect(machine.collectionID == nil)
        #expect(machine.collectionMovies.isEmpty)
    }

    @Test func `series snapshots do not expose the previous title before replacement preparation`() {
        let original = Series(id: "first", seriesId: 1, name: "First")
        original.episodes = [episode(1, season: 3, series: original)]
        let machine = SeriesDetailLoadMachine(series: original)
        machine.recomputeSeasons(original)
        #expect(machine.snapshot(for: original).availableSeasons == [3])
        #expect(machine.snapshot(for: original).selectedSeason == 3)

        let replacement = Series(id: "second", seriesId: 2, name: "Second")
        let snapshot = machine.snapshot(for: replacement)
        #expect(snapshot.availableSeasons.isEmpty)
        #expect(snapshot.episodesBySeason.isEmpty)
        #expect(snapshot.similar.isEmpty)
        #expect(snapshot.selectedSeason == 1)
        #expect(!snapshot.isLoadingEpisodes)
        #expect(snapshot.isLoadingTMDB == detailNeedsTMDBFetch(tmdbId: replacement.tmdbId, enrichedAt: replacement.tmdbEnrichedAt))
        // Reading the safe snapshot does not reset the original presentation.
        #expect(machine.contentID == original.id)
        #expect(machine.snapshot(for: original).availableSeasons == [3])
    }

    @Test func `movie snapshot readiness uses the requested title rather than the previous load`() async throws {
        let container = try makeTestContainer()
        let original = Movie(id: "first", streamId: 1, name: "First")
        let machine = MovieDetailLoadMachine(movie: original)
        await machine.load(original, in: container.mainContext)
        let replacement = Movie(id: "second", streamId: 2, name: "Second")
        replacement.tmdbId = 123
        let snapshot = machine.snapshot(for: replacement)
        #expect(snapshot.isLoadingTMDB == detailNeedsTMDBFetch(tmdbId: replacement.tmdbId, enrichedAt: nil))
        #expect(snapshot.collectionMovies.isEmpty)
        #expect(snapshot.similar.isEmpty)
        #expect(machine.contentID == original.id)
    }
}
