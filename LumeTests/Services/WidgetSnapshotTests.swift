import Foundation
@testable import Lume
import SwiftData
import Testing

// MARK: - Deep-link round trip

/// `WidgetDeepLink` (LumeShared) builds the URLs the widgets emit; `DeepLink`
/// (app) parses them. These tests are the contract keeping the two in sync.
struct DeepLinkWidgetRoundTripTests {
    @Test func `play movie link round-trips`() throws {
        let url = try #require(WidgetDeepLink.play(kind: .movie, id: "ABC-123"))
        #expect(DeepLink(url: url) == .playMovie(id: "ABC-123"))
    }

    @Test func `play episode link round-trips`() throws {
        let url = try #require(WidgetDeepLink.play(kind: .episode, id: "ABC-9-1-2"))
        #expect(DeepLink(url: url) == .playEpisode(id: "ABC-9-1-2"))
    }

    @Test func `play live link round-trips`() throws {
        let url = try #require(WidgetDeepLink.play(kind: .live, id: "ABC-55"))
        #expect(DeepLink(url: url) == .playLive(id: "ABC-55"))
    }

    @Test func `open movie link round-trips`() throws {
        let url = try #require(WidgetDeepLink.openMovie(id: "ABC-42"))
        #expect(DeepLink(url: url) == .openMovie(id: "ABC-42"))
    }

    @Test func `open series link round-trips`() throws {
        let url = try #require(WidgetDeepLink.openSeries(id: "ABC-77"))
        #expect(DeepLink(url: url) == .openSeries(id: "ABC-77"))
    }

    @Test func `provider ids with reserved URL characters survive the round trip`() throws {
        let hostileID = "ABC-my show/№1 ?ep=2&x=ä"
        let url = try #require(WidgetDeepLink.play(kind: .live, id: hostileID))
        #expect(DeepLink(url: url) == .playLive(id: hostileID))
    }

    @Test func `a series cannot be a play target`() {
        #expect(WidgetDeepLink.play(kind: .series, id: "ABC-1") == nil)
    }

    @Test func `builder and parser agree on the scheme`() {
        #expect(WidgetDeepLink.scheme == DeepLink.scheme)
    }
}

// MARK: - Snapshot codability

struct WidgetSnapshotCodingTests {
    @Test func `snapshot survives an encode-decode round trip`() throws {
        let deepLink = try #require(WidgetDeepLink.play(kind: .movie, id: "p-1"))
        let snapshot = WidgetSnapshot(
            generatedAt: Date(timeIntervalSince1970: 1_700_000_000),
            sections: [WidgetSection(id: "home/continueWatching", title: "Continue Watching", items: [WidgetMediaItem(
                id: "movie-p-1", kind: .movie, title: "A", subtitle: "2024",
                imageURL: URL(string: "https://example.com/a.jpg"), progress: 0.5, deepLink: deepLink
            )])]
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(WidgetSnapshot.self, from: encoder.encode(snapshot))
        #expect(decoded == snapshot)
    }
}

// MARK: - Exporter

@MainActor
struct WidgetSnapshotExporterTests {
    private static let homeContinueWatching = TopShelfSource(surface: .home, ref: .builtin(.continueWatching))
    private static let homeFavorites = TopShelfSource(surface: .home, ref: .builtin(.favorites))

    /// The snapshot with `sources` promoted, list rows showing `recorded`.
    private func snapshot(
        _ container: ModelContainer, _ playlist: Playlist,
        _ sources: [TopShelfSource] = [homeContinueWatching, homeFavorites],
        recorded: [TopShelfSource: [String]] = [:],
        isChildProfile: Bool = false
    ) -> WidgetSnapshot {
        WidgetSnapshotExporter.makeSnapshot(
            container: container,
            rows: sources.map { TopShelfRowPlan(source: $0, title: $0.token, recordedItems: recorded[$0] ?? []) },
            storedPlaylistID: playlist.id.uuidString,
            isChildProfile: isChildProfile
        )
    }

    private func items(_ snapshot: WidgetSnapshot, _ source: TopShelfSource) -> [WidgetMediaItem] {
        snapshot.sections.first { $0.id == source.token }?.items ?? []
    }

    /// One playlist with resumable, watched, favorite and EPG-backed content.
    private func seedContainer() throws -> (ModelContainer, Playlist) {
        let container = try makeTestContainer()
        let context = container.mainContext
        let playlist = Playlist(name: "Test", serverURL: "http://example.com", username: "u", password: "p")
        context.insert(playlist)
        let prefix = playlist.id.uuidString

        let resumable = Movie(id: "\(prefix)-m1", streamId: 1, name: "Resumable", streamIcon: "https://img/m1.jpg")
        resumable.durationSecs = 3600
        resumable.watchProgress = 900
        resumable.lastWatchedDate = Date(timeIntervalSinceNow: -3600)
        resumable.backdropPath = "/m1-backdrop.jpg"
        context.insert(resumable)

        let watched = Movie(id: "\(prefix)-m2", streamId: 2, name: "Watched")
        watched.isWatched = true
        watched.watchProgress = 3600
        watched.lastWatchedDate = Date(timeIntervalSinceNow: -7200)
        context.insert(watched)

        let favoriteMovie = Movie(id: "\(prefix)-m3", streamId: 3, name: "Favorite Movie")
        favoriteMovie.isFavorite = true
        favoriteMovie.favoriteOrder = 1
        context.insert(favoriteMovie)

        let series = Series(id: "\(prefix)-s1", seriesId: 10, name: "Show")
        series.lastWatchedDate = Date(timeIntervalSinceNow: -60)
        series.isFavorite = true
        series.favoriteOrder = 0
        context.insert(series)
        let episodeDone = Episode(id: "\(prefix)-s1-1-1", episodeId: "e1", title: "Pilot", containerExtension: "mp4", seasonNum: 1, episodeNum: 1, series: series)
        episodeDone.setWatched(true)
        context.insert(episodeDone)
        let episodeInProgress = Episode(id: "\(prefix)-s1-1-2", episodeId: "e2", title: "Second", containerExtension: "mp4", seasonNum: 1, episodeNum: 2, series: series)
        episodeInProgress.durationSecs = 1200
        episodeInProgress.watchProgress = 600
        episodeInProgress.lastWatchedDate = Date(timeIntervalSinceNow: -60)
        context.insert(episodeInProgress)

        let channel = LiveStream(id: "\(prefix)-l1", streamId: 100, name: "News 24", streamIcon: "https://img/l1.png", epgChannelId: "news24.example")
        channel.isFavorite = true
        channel.favoriteOrder = 2
        context.insert(channel)

        let now = Date()
        context.insert(EPGListing(id: "epg-1", channelId: "news24.example", title: "Evening News", listingDescription: "", start: now.addingTimeInterval(-600), end: now.addingTimeInterval(1200)))
        context.insert(EPGListing(id: "epg-2", channelId: "news24.example", title: "Weather", listingDescription: "", start: now.addingTimeInterval(1200), end: now.addingTimeInterval(2400)))

        try context.save()
        return (container, playlist)
    }

    @Test func `continue watching resumes movies and the series' in-progress episode`() throws {
        let (container, playlist) = try seedContainer()
        let snapshot = snapshot(container, playlist)

        // The series was watched more recently than the movie.
        #expect(items(snapshot, Self.homeContinueWatching).map(\.kind) == [.episode, .movie])
        let episode = try #require(items(snapshot, Self.homeContinueWatching).first)
        #expect(episode.title == "Show")
        // The rail's label, built by the rail's own code.
        #expect(episode.subtitle == ContinueWatching.seriesLabel(
            SeriesContinuation(season: 1, episode: 2, fraction: 0.5, remaining: 600)
        ))
        #expect(episode.deepLink == WidgetDeepLink.play(kind: .episode, id: "\(playlist.id.uuidString)-s1-1-2"))
        #expect(episode.progress == 0.5)
        let movie = try #require(items(snapshot, Self.homeContinueWatching).last)
        #expect(movie.title == "Resumable")
        #expect(movie.backdropURL == TMDBClient.backdropURL("/m1-backdrop.jpg"))
        // Select opens the detail screen — an episode's is its show's.
        #expect(movie.detailLink == WidgetDeepLink.openMovie(id: "\(playlist.id.uuidString)-m1"))
        #expect(episode.detailLink == WidgetDeepLink.openSeries(id: "\(playlist.id.uuidString)-s1"))
        #expect(movie.progress == 0.25)
        // The fully-watched movie must not resurface.
        #expect(!items(snapshot, Self.homeContinueWatching).contains { $0.title == "Watched" })
    }

    @Test func `favorites interleave kinds in unified order`() throws {
        let (container, playlist) = try seedContainer()
        let snapshot = snapshot(container, playlist)

        #expect(items(snapshot, Self.homeFavorites).map(\.title) == ["Show", "Favorite Movie", "News 24"])
        #expect(items(snapshot, Self.homeFavorites).map(\.kind) == [.series, .movie, .live])
    }

    @Test func `a child profile keeps restricted categories out of the snapshot`() throws {
        let (container, playlist) = try seedContainer()
        let context = container.mainContext
        let restricted = Lume.Category(apiId: "9", name: "Adults", parentId: 0, type: .vod, playlist: playlist)
        restricted.isRestricted = true
        context.insert(restricted)
        let hidden = Movie(id: "\(playlist.id.uuidString)-m9", streamId: 9, name: "Hidden", categoryId: restricted.id)
        hidden.isFavorite = true
        hidden.durationSecs = 3600
        hidden.watchProgress = 600
        hidden.lastWatchedDate = Date()
        context.insert(hidden)
        try context.save()

        let adult = snapshot(container, playlist)
        #expect(items(adult, Self.homeFavorites).contains { $0.title == "Hidden" })

        let child = snapshot(container, playlist, isChildProfile: true)
        #expect(!items(child, Self.homeFavorites).contains { $0.title == "Hidden" })
        #expect(!items(child, Self.homeContinueWatching).contains { $0.title == "Hidden" })
    }

    @Test func `hidden categories and channels stay out for every profile`() throws {
        let (container, playlist) = try seedContainer()
        let context = container.mainContext
        let prefix = playlist.id.uuidString
        let hiddenCategory = Lume.Category(apiId: "8", name: "Hidden", parentId: 0, type: .vod, playlist: playlist)
        hiddenCategory.isHidden = true
        context.insert(hiddenCategory)
        let movie = Movie(id: "\(prefix)-m8", streamId: 8, name: "In Hidden Category", categoryId: hiddenCategory.id)
        movie.isFavorite = true
        movie.durationSecs = 3600
        movie.watchProgress = 600
        movie.lastWatchedDate = Date()
        context.insert(movie)
        let channel = LiveStream(id: "\(prefix)-l2", streamId: 101, name: "Hidden Channel")
        channel.isFavorite = true
        channel.isHidden = true
        context.insert(channel)
        try context.save()

        let snapshot = snapshot(container, playlist)
        #expect(!items(snapshot, Self.homeFavorites).contains { $0.title == "In Hidden Category" })
        #expect(!items(snapshot, Self.homeContinueWatching).contains { $0.title == "In Hidden Category" })
        #expect(!items(snapshot, Self.homeFavorites).contains { $0.title == "Hidden Channel" })
    }

    @Test func `content from other playlists is excluded`() throws {
        let (container, playlist) = try seedContainer()
        let context = container.mainContext
        let foreign = Movie(id: "\(UUID().uuidString)-x1", streamId: 50, name: "Foreign")
        foreign.isFavorite = true
        foreign.durationSecs = 3600
        foreign.watchProgress = 60
        foreign.lastWatchedDate = Date()
        context.insert(foreign)
        try context.save()

        let snapshot = snapshot(container, playlist)
        #expect(!items(snapshot, Self.homeFavorites).contains { $0.title == "Foreign" })
        #expect(!items(snapshot, Self.homeContinueWatching).contains { $0.title == "Foreign" })
    }

    @Test func `no playlists produces an empty snapshot`() throws {
        let container = try makeTestContainer()
        let snapshot = WidgetSnapshotExporter.makeSnapshot(
            container: container,
            rows: [TopShelfRowPlan(source: Self.homeFavorites, title: "", recordedItems: [])],
            storedPlaylistID: "", isChildProfile: false
        )
        #expect(snapshot.sections.isEmpty)
    }

    /// Nothing promoted is the default, and means the Top Shelf is off.
    @Test func `no promoted rows produce no sections`() throws {
        let (container, playlist) = try seedContainer()
        #expect(snapshot(container, playlist, []).sections.isEmpty)
    }

    /// Rows keep the user's order, each under the title it was planned with.
    @Test func `sections follow the promoted order`() throws {
        let (container, playlist) = try seedContainer()
        let result = snapshot(container, playlist, [Self.homeFavorites, Self.homeContinueWatching])
        #expect(result.sections.map(\.id) == [Self.homeFavorites.token, Self.homeContinueWatching.token])
    }

    /// A Movies or Series row only ever shows its own kind; Home mixes them.
    @Test func `each surface keeps to its own kind`() throws {
        let (container, playlist) = try seedContainer()
        let movies = TopShelfSource(surface: .movies, ref: .builtin(.favorites))
        let series = TopShelfSource(surface: .series, ref: .builtin(.favorites))
        let result = snapshot(container, playlist, [movies, series])
        #expect(items(result, movies).map(\.title) == ["Favorite Movie"])
        #expect(items(result, series).map(\.title) == ["Show"])
    }

    /// Finished titles, the opposite of Continue Watching.
    /// The in-app rail keeps a show whose next episode is waiting; so must
    /// the Top Shelf, playing that episode.
    @Test func `continue watching keeps a show with its next episode waiting`() throws {
        let (container, playlist) = try seedContainer()
        let prefix = playlist.id.uuidString
        let context = container.mainContext
        let episode = try #require(try context.fetch(FetchDescriptor<Episode>()).first { $0.id == "\(prefix)-s1-1-2" })
        episode.watchProgress = 0
        try context.save()

        let continuing = TopShelfSource(surface: .series, ref: .builtin(.continueWatching))
        let item = try #require(items(snapshot(container, playlist, [continuing]), continuing).first)
        #expect(item.title == "Show")
        #expect(item.deepLink == WidgetDeepLink.play(kind: .episode, id: "\(prefix)-s1-1-2"))
        #expect(item.progress == nil)
    }

    /// A show with nothing left moves from Continue Watching to Watch Again,
    /// as on the rails.
    @Test func `a finished show is in watch again, not continue watching`() throws {
        let (container, playlist) = try seedContainer()
        let prefix = playlist.id.uuidString
        let context = container.mainContext
        let episode = try #require(try context.fetch(FetchDescriptor<Episode>()).first { $0.id == "\(prefix)-s1-1-2" })
        episode.setWatched(true)
        try context.save()

        let continuing = TopShelfSource(surface: .series, ref: .builtin(.continueWatching))
        let watchAgain = TopShelfSource(surface: .series, ref: .builtin(.recentlyWatched))
        let result = snapshot(container, playlist, [continuing, watchAgain])
        #expect(items(result, continuing).isEmpty)
        #expect(items(result, watchAgain).map(\.title) == ["Show"])
    }

    @Test func `watch again shows finished movies`() throws {
        let (container, playlist) = try seedContainer()
        let watchAgain = TopShelfSource(surface: .movies, ref: .builtin(.recentlyWatched))
        #expect(items(snapshot(container, playlist, [watchAgain]), watchAgain).map(\.title) == ["Watched"])
    }

    /// A list row shows what the app last loaded, in order, still under the
    /// visibility rules and scoped to the active playlist.
    @Test func `a list row resolves the titles it last showed`() throws {
        let (container, playlist) = try seedContainer()
        let prefix = playlist.id.uuidString
        let trending = TopShelfSource(surface: .home, ref: .builtin(.trendingMovies))
        let recorded = ["movie-\(prefix)-m3", "series-\(prefix)-s1", "movie-\(UUID().uuidString)-x9", "bogus"]
        let result = snapshot(container, playlist, [trending], recorded: [trending: recorded])
        #expect(items(result, trending).map(\.title) == ["Favorite Movie", "Show"])
    }
}

// MARK: - Link resolution

@MainActor
struct WidgetLinkResolverTests {
    private func seed() throws -> (ModelContainer, Playlist) {
        let container = try makeTestContainer()
        let context = container.mainContext
        let playlist = Playlist(name: "Test", serverURL: "http://example.com", username: "u", password: "p")
        context.insert(playlist)
        let prefix = playlist.id.uuidString
        let restricted = Lume.Category(apiId: "9", name: "Adults", parentId: 0, type: .series, playlist: playlist)
        restricted.isRestricted = true
        context.insert(restricted)

        context.insert(Movie(id: "\(prefix)-m1", streamId: 1, name: "Movie"))
        let series = Series(id: "\(prefix)-s1", seriesId: 10, name: "Show", categoryId: restricted.id)
        context.insert(series)
        context.insert(Episode(
            id: "\(prefix)-s1-1-1", episodeId: "e1", title: "Pilot", containerExtension: "mp4",
            seasonNum: 1, episodeNum: 1, series: series
        ))
        let hiddenChannel = LiveStream(id: "\(prefix)-l1", streamId: 100, name: "Hidden")
        hiddenChannel.isHidden = true
        context.insert(hiddenChannel)
        try context.save()
        return (container, playlist)
    }

    private func resolve(_ link: DeepLink, _ container: ModelContainer, child: Bool = false, restricted: Set<String> = [])
        -> WidgetLinkResolver.Target?
    {
        WidgetLinkResolver.resolve(
            link,
            in: container.mainContext,
            restriction: ContentRestriction(isActive: child, restrictedCategoryIDs: restricted)
        )
    }

    @Test func `a play movie link resolves to playable media`() throws {
        let (container, playlist) = try seed()
        let target = resolve(.playMovie(id: "\(playlist.id.uuidString)-m1"), container)
        guard case let .play(media) = target else {
            Issue.record("expected playable media, got \(String(describing: target))")
            return
        }
        #expect(media.title == "Movie")
    }

    @Test func `an episode follows its show's restriction`() throws {
        let (container, playlist) = try seed()
        let prefix = playlist.id.uuidString
        let restrictedID = try #require(
            container.mainContext.fetch(FetchDescriptor<Lume.Category>(predicate: #Predicate { $0.isRestricted })).first
        ).id
        let link = DeepLink.playEpisode(id: "\(prefix)-s1-1-1")

        #expect(resolve(link, container) != nil)
        #expect(resolve(link, container, child: true, restricted: [restrictedID]) == nil)
        #expect(resolve(.openSeries(id: "\(prefix)-s1"), container, child: true, restricted: [restrictedID]) == nil)
    }

    @Test func `an open movie link resolves to the movie`() throws {
        let (container, playlist) = try seed()
        let target = resolve(.openMovie(id: "\(playlist.id.uuidString)-m1"), container)
        guard case let .openMovie(movie) = target else {
            Issue.record("expected a movie, got \(String(describing: target))")
            return
        }
        #expect(movie.name == "Movie")
    }

    @Test func `a hidden channel does not play`() throws {
        let (container, playlist) = try seed()
        #expect(resolve(.playLive(id: "\(playlist.id.uuidString)-l1"), container) == nil)
    }

    @Test func `an unknown id resolves to nothing`() throws {
        let (container, playlist) = try seed()
        #expect(resolve(.playMovie(id: "\(playlist.id.uuidString)-missing"), container) == nil)
    }
}
