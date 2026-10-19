import Foundation
@testable import Lume
import SwiftData
import Testing

@MainActor
struct CloudWatchlistQueryTests {
    @Test func `watchlist reads keep their index ordering without limiting state`() {
        let movies = CloudWatchlistQuery.movies
        let series = CloudWatchlistQuery.series
        #expect(movies.sortBy == [SortDescriptor(\Movie.addedToWatchlistDate)])
        #expect(series.sortBy == [SortDescriptor(\Series.addedToWatchlistDate)])
        #expect(movies.fetchLimit == nil)
        #expect(series.fetchLimit == nil)
        #expect(movies.fetchOffset == 0)
        #expect(series.fetchOffset == 0)
    }

    @Test func `ordered watchlist reads preserve every date and exclude nil on SQLite`() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let schema = Schema([Movie.self, Series.self, Episode.self, CastMember.self])
        let config = ModelConfiguration(schema: schema, url: directory.appendingPathComponent("catalog.store"), cloudKitDatabase: .none)
        let container = try ModelContainer(for: schema, configurations: config)
        let context = ModelContext(container)
        context.autosaveEnabled = false
        // More than a rail's 20 titles, tied dates, and dates on either side of
        // the reference epoch: no preview limit or guessed cutoff may lose one.
        let dates = [Date.distantPast, Date(timeIntervalSinceReferenceDate: -1),
                     Date(timeIntervalSinceReferenceDate: 0), Date.distantFuture]
        for index in 0 ..< 32 {
            let movie = Movie(id: "movie-\(index)", streamId: index, name: "Movie")
            movie.addedToWatchlistDate = dates[index % dates.count]
            context.insert(movie)
            let series = Series(id: "series-\(index)", seriesId: index, name: "Series")
            series.addedToWatchlistDate = dates[index % dates.count]
            context.insert(series)
        }
        context.insert(Movie(id: "movie-nil", streamId: 99, name: "Not watchlisted"))
        context.insert(Series(id: "series-nil", seriesId: 99, name: "Not watchlisted"))
        try context.save()

        let cold = ModelContext(container)
        let movies = try cold.fetch(CloudWatchlistQuery.movies)
        let series = try cold.fetch(CloudWatchlistQuery.series)
        #expect(Set(movies.map(\.id)) == Set((0 ..< 32).map { "movie-\($0)" }))
        #expect(Set(series.map(\.id)) == Set((0 ..< 32).map { "series-\($0)" }))
        #expect(movies.allSatisfy { $0.addedToWatchlistDate != nil })
        #expect(series.allSatisfy { $0.addedToWatchlistDate != nil })
        #expect(Set(movies.compactMap(\.addedToWatchlistDate)) == Set(dates))
        #expect(Set(series.compactMap(\.addedToWatchlistDate)) == Set(dates))
    }
}

@MainActor
@Suite(.serialized, .globalState)
struct CloudWatchlistStateTests {
    private let playlistID = UUID()
    private var prefix: String {
        playlistID.uuidString + "-"
    }

    @Test func `reconcile exports watchlist-only rows once alongside other state`() async throws {
        let container = try makeProfileTestContainer()
        let context = container.mainContext
        let profile = UUID()
        let previous = ActiveProfileStore.current
        ActiveProfileStore.current = profile
        defer { ActiveProfileStore.current = previous }
        let expected = seed(in: context)
        try context.save()
        let shadow = freshShadow()
        let engine = CloudSyncEngine(container: container, shadow: shadow)

        let result = await engine.reconcile()
        #expect(!result.failed)
        #expect(result.contentPushed == expected.count)
        let states = try context.fetch(FetchDescriptor<UserContentState>())
        #expect(states.count == expected.count)
        #expect(Set(states.map(\.contentId)) == Set(expected.keys))
        #expect(states.allSatisfy { $0.profileID == profile })
        for state in states {
            #expect(state.addedToWatchlistDate == expected[state.contentId])
        }
        let again = await engine.reconcile()
        #expect(!again.failed)
        #expect(again.contentPushed == 0)
        #expect(again.contentPulled == 0)
    }

    @Test func `profile round trip exports resets and restores watchlist-only rows`() async throws {
        let container = try makeProfileTestContainer()
        let context = container.mainContext
        let profileA = UUID()
        let profileB = UUID()
        let previous = ActiveProfileStore.current
        ActiveProfileStore.current = profileA
        defer { ActiveProfileStore.current = previous }
        let expected = seed(in: context)
        let bDate = Date(timeIntervalSinceReferenceDate: 500)
        let movieID = prefix + "movie-0"
        let seriesID = prefix + "series-0"
        context.insert(UserContentState(contentId: movieID, kind: .movie, profileID: profileB, addedToWatchlistDate: bDate))
        context.insert(UserContentState(contentId: seriesID, kind: .series, profileID: profileB, addedToWatchlistDate: bDate))
        try context.save()
        let engine = CloudSyncEngine(container: container, shadow: freshShadow())

        try await engine.switchProfile(from: profileA, to: profileB)
        let firstProjection = ModelContext(container)
        var movies = try firstProjection.fetch(FetchDescriptor<Movie>())
        var series = try firstProjection.fetch(FetchDescriptor<Series>())
        #expect(movies.filter { $0.addedToWatchlistDate != nil }.map(\.id) == [movieID])
        #expect(series.filter { $0.addedToWatchlistDate != nil }.map(\.id) == [seriesID])
        #expect(movies.first { $0.id == movieID }?.addedToWatchlistDate == bDate)
        #expect(series.first { $0.id == seriesID }?.addedToWatchlistDate == bDate)
        let firstReconcile = await engine.reconcile()
        #expect(!firstReconcile.failed)

        try await engine.switchProfile(from: profileB, to: profileA)
        let secondProjection = ModelContext(container)
        movies = try secondProjection.fetch(FetchDescriptor<Movie>())
        series = try secondProjection.fetch(FetchDescriptor<Series>())
        #expect(movies.count(where: { $0.addedToWatchlistDate != nil }) == 32)
        #expect(series.count(where: { $0.addedToWatchlistDate != nil }) == 32)
        for movie in movies where movie.id != prefix + "movie-nil" {
            #expect(movie.addedToWatchlistDate == expected[movie.id])
        }
        for item in series where item.id != prefix + "series-nil" {
            #expect(item.addedToWatchlistDate == expected[item.id])
        }
        let states = try context.fetch(FetchDescriptor<UserContentState>()).filter { $0.profileID == profileA }
        #expect(states.count == expected.count)
        let secondReconcile = await engine.reconcile()
        #expect(!secondReconcile.failed)
    }

    private func seed(in context: ModelContext) -> [String: Date] {
        let playlist = Playlist(name: "Synthetic", serverURL: "https://example.invalid", username: "", password: "")
        playlist.id = playlistID
        context.insert(playlist)
        var expected: [String: Date] = [:]
        for index in 0 ..< 32 {
            let date = Date(timeIntervalSinceReferenceDate: Double(index - 16))
            let movie = Movie(id: prefix + "movie-\(index)", streamId: index, name: "Movie")
            movie.addedToWatchlistDate = date
            // Overlap several conditions; the union must still export once.
            movie.isFavorite = index == 0
            movie.isWatched = index == 0
            movie.watchProgress = index == 0 ? 42 : 0
            movie.recommendationVoteRaw = index == 0 ? 1 : 0
            context.insert(movie)
            expected[movie.id] = date
            let series = Series(id: prefix + "series-\(index)", seriesId: index, name: "Series")
            series.addedToWatchlistDate = date
            series.isFavorite = index == 0
            series.recommendationVoteRaw = index == 0 ? -1 : 0
            context.insert(series)
            expected[series.id] = date
        }
        context.insert(Movie(id: prefix + "movie-nil", streamId: 99, name: "No state"))
        context.insert(Series(id: prefix + "series-nil", seriesId: 99, name: "No state"))
        return expected
    }

    private func freshShadow() -> CloudSyncShadow {
        CloudSyncShadow(defaults: UserDefaults(suiteName: "watchlist-state-test.\(UUID())")!)
    }
}
