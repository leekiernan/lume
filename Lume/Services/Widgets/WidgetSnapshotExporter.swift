//
//  WidgetSnapshotExporter.swift
//  Lume
//
//  Builds the `WidgetSnapshot` the tvOS Top Shelf renders, and writes it to
//  the shared App Group container. Extensions never query the
//  catalog themselves — SwiftData stays app-only and the extension reads a
//  small precomputed file instead (the reliable pattern for widget data).
//
//  Runs off the main actor on its own `ModelContext`, mirroring the Home
//  screen's rails: Recently Watched (resumable movies + series) and Favorites
//  (unified `favoriteOrder`). Applies
//  the same visibility rules Home does — categories hidden in Content
//  Management, hidden channels, and restricted categories for a child profile.
//
//  Exported on tvOS only, the one platform that ships an extension reading
//  the snapshot (`LumeTopShelf`). Building it is platform-neutral, for tests.
//

import Foundation
import OSLog
import SwiftData
#if os(tvOS)
    import TVServices
#endif

enum WidgetSnapshotExporter {
    /// Every list holds as many items as the largest Top Shelf section can
    /// show; the widgets take fewer.
    private static let continueWatchingLimit = TopShelfConfiguration.maxItemsPerSection
    private static let favoritesLimit = TopShelfConfiguration.maxItemsPerSection

    /// Exports a fresh snapshot for the active playlist/profile and tells the
    /// Top Shelf to re-read it.
    nonisolated static func export(container: ModelContainer, isChildProfile: Bool, now: Date = Date()) {
        let storedID = UserDefaults.standard.string(forKey: PlaylistSelectionStore.key) ?? ""
        var snapshot = makeSnapshot(
            container: container,
            storedPlaylistID: storedID,
            isChildProfile: isChildProfile,
            now: now
        )
        #if os(tvOS)
            snapshot.topShelf = TopShelfSettings.configuration()
        #endif
        do {
            try WidgetDataStore.save(snapshot)
        } catch {
            Logger.database.error("Widget snapshot export failed: \(error.localizedDescription, privacy: .public)")
            return
        }
        #if os(tvOS)
            TVTopShelfContentProvider.topShelfContentDidChange()
        #endif
    }

    /// Builds the snapshot for the active playlist. Hidden categories and
    /// channels never enter it, and restricted categories stay out while a
    /// child profile is active — the Top Shelf must not leak content the app hides.
    /// Internal (not private) so tests can build snapshots without touching the
    /// App Group container.
    nonisolated static func makeSnapshot(
        container: ModelContainer,
        storedPlaylistID: String,
        isChildProfile: Bool,
        now: Date = Date()
    ) -> WidgetSnapshot {
        let context = ModelContext(container)
        let playlists = (try? context.fetch(FetchDescriptor<Playlist>())) ?? []
        guard let playlist = playlists.active(for: storedPlaylistID) else {
            var empty = WidgetSnapshot.empty
            empty.generatedAt = now
            return empty
        }

        let playlistPrefix = "\(playlist.id.uuidString)-"
        let restriction = ContentRestriction(
            isActive: isChildProfile,
            restrictedCategoryIDs: isChildProfile ? categoryIDs(in: context, matching: #Predicate { $0.isRestricted }) : [],
            hiddenCategoryIDs: categoryIDs(in: context, matching: #Predicate { $0.isHidden })
        )

        return WidgetSnapshot(
            generatedAt: now,
            continueWatching: continueWatching(in: context, prefix: playlistPrefix, restriction: restriction),
            favorites: favorites(in: context, prefix: playlistPrefix, restriction: restriction)
        )
    }

    private nonisolated static func categoryIDs(
        in context: ModelContext,
        matching predicate: Predicate<Category>
    ) -> Set<String> {
        let categories = (try? context.fetch(FetchDescriptor<Category>(predicate: predicate))) ?? []
        return Set(categories.map(\.id))
    }

    // MARK: - Continue Watching

    /// Resumable titles, most recently watched first: partially-watched movies
    /// plus the in-progress episode of recently-watched series (the same resume
    /// resolution as the Home rail, see `HomeMediaItem.progress`).
    private nonisolated static func continueWatching(
        in context: ModelContext,
        prefix: String,
        restriction: ContentRestriction
    ) -> [WidgetMediaItem] {
        let entries = resumableMovies(in: context, prefix: prefix, restriction: restriction)
            + resumableEpisodes(in: context, prefix: prefix, restriction: restriction)
        return entries
            .sorted { $0.lastWatched > $1.lastWatched }
            .prefix(continueWatchingLimit)
            .map(\.item)
    }

    private nonisolated static func resumableMovies(
        in context: ModelContext,
        prefix: String,
        restriction: ContentRestriction
    ) -> [(lastWatched: Date, item: WidgetMediaItem)] {
        var entries: [(lastWatched: Date, item: WidgetMediaItem)] = []

        var movieDescriptor = FetchDescriptor<Movie>(
            predicate: #Predicate { $0.lastWatchedDate != nil && !$0.isWatched && $0.watchProgress > 0 },
            sortBy: [SortDescriptor(\.lastWatchedDate, order: .reverse)]
        )
        movieDescriptor.fetchLimit = 30
        let movies = (try? context.fetch(movieDescriptor)) ?? []
        for movie in movies where movie.id.hasPrefix(prefix) && !restriction.hides(categoryID: movie.categoryId) {
            guard let lastWatched = movie.lastWatchedDate,
                  let deepLink = WidgetDeepLink.play(kind: .movie, id: movie.id) else { continue }
            var progress: Double?
            if let duration = movie.durationSecs, duration > 0 {
                progress = min(movie.watchProgress / Double(duration), 1)
            }
            entries.append((lastWatched, WidgetMediaItem(
                id: "movie-\(movie.id)",
                kind: .movie,
                title: movie.name,
                subtitle: movie.releaseDate,
                imageURL: URL(string: movie.streamIcon ?? ""),
                backdropURL: TMDBClient.backdropURL(movie.backdropPath),
                progress: progress,
                deepLink: deepLink,
                detailLink: WidgetDeepLink.openMovie(id: movie.id)
            )))
        }
        return entries
    }

    /// The most recently watched in-progress episode of each show, found the
    /// way `SeriesResumeLoader` finds it: one fetch over the indexed watch-state
    /// columns rather than faulting every recently watched show's `episodes`.
    private nonisolated static func resumableEpisodes(
        in context: ModelContext,
        prefix: String,
        restriction: ContentRestriction
    ) -> [(lastWatched: Date, item: WidgetMediaItem)] {
        var descriptor = FetchDescriptor<Episode>(
            predicate: #Predicate { $0.watchProgress > 0 && $0.isWatched == false }
        )
        descriptor.relationshipKeyPathsForPrefetching = [\.series]
        let episodes = (try? context.fetch(descriptor)) ?? []

        var newest: [String: Episode] = [:]
        for episode in episodes {
            guard let show = episode.series, show.id.hasPrefix(prefix),
                  !restriction.hides(categoryID: show.categoryId) else { continue }
            let watched = episode.lastWatchedDate ?? .distantPast
            if let seen = newest[show.id], (seen.lastWatchedDate ?? .distantPast) >= watched { continue }
            newest[show.id] = episode
        }
        return newest.values.compactMap(resumeEntry)
    }

    private nonisolated static func resumeEntry(for episode: Episode) -> (lastWatched: Date, item: WidgetMediaItem)? {
        guard let show = episode.series,
              let lastWatched = show.lastWatchedDate ?? episode.lastWatchedDate,
              let deepLink = WidgetDeepLink.play(kind: .episode, id: episode.id) else { return nil }
        var progress: Double?
        if let duration = episode.durationSecs, duration > 0 {
            progress = min(episode.watchProgress / Double(duration), 1)
        }
        return (lastWatched, WidgetMediaItem(
            id: "episode-\(episode.id)",
            kind: .episode,
            title: show.name,
            subtitle: "S\(episode.seasonNum) E\(episode.episodeNum) · \(episode.title)",
            imageURL: URL(string: show.cover ?? episode.movieImage ?? ""),
            backdropURL: TMDBClient.backdropURL(show.backdropPath),
            progress: progress,
            deepLink: deepLink,
            detailLink: WidgetDeepLink.openSeries(id: show.id)
        ))
    }

    // MARK: - Favorites

    /// Favorite movies, series and channels interleaved by the user's unified
    /// `favoriteOrder` (nil orders last, then alphabetical — same as Home).
    private nonisolated static func favorites(
        in context: ModelContext,
        prefix: String,
        restriction: ContentRestriction
    ) -> [WidgetMediaItem] {
        var entries: [(order: Int, item: WidgetMediaItem)] = []

        let movies = (try? context.fetch(FetchDescriptor<Movie>(predicate: #Predicate { $0.isFavorite }))) ?? []
        for movie in movies where movie.id.hasPrefix(prefix) && !restriction.hides(categoryID: movie.categoryId) {
            guard let deepLink = WidgetDeepLink.play(kind: .movie, id: movie.id) else { continue }
            entries.append((movie.favoriteOrder ?? Int.max, WidgetMediaItem(
                id: "movie-\(movie.id)",
                kind: .movie,
                title: movie.name,
                subtitle: nil,
                imageURL: URL(string: movie.streamIcon ?? ""),
                backdropURL: TMDBClient.backdropURL(movie.backdropPath),
                progress: nil,
                deepLink: deepLink,
                detailLink: WidgetDeepLink.openMovie(id: movie.id)
            )))
        }

        let series = (try? context.fetch(FetchDescriptor<Series>(predicate: #Predicate { $0.isFavorite }))) ?? []
        for show in series where show.id.hasPrefix(prefix) && !restriction.hides(categoryID: show.categoryId) {
            guard let deepLink = WidgetDeepLink.openSeries(id: show.id) else { continue }
            entries.append((show.favoriteOrder ?? Int.max, WidgetMediaItem(
                id: "series-\(show.id)",
                kind: .series,
                title: show.name,
                subtitle: nil,
                imageURL: URL(string: show.cover ?? ""),
                backdropURL: TMDBClient.backdropURL(show.backdropPath),
                progress: nil,
                deepLink: deepLink,
                detailLink: deepLink
            )))
        }

        let streams = (try? context.fetch(
            FetchDescriptor<LiveStream>(predicate: #Predicate { $0.isFavorite && $0.isHidden == false })
        )) ?? []
        for stream in streams where stream.id.hasPrefix(prefix) && !restriction.hides(categoryID: stream.categoryId) {
            guard let deepLink = WidgetDeepLink.play(kind: .live, id: stream.id) else { continue }
            entries.append((stream.favoriteOrder ?? Int.max, WidgetMediaItem(
                id: "live-\(stream.id)",
                kind: .live,
                title: stream.name,
                subtitle: nil,
                imageURL: URL(string: stream.streamIcon ?? ""),
                progress: nil,
                deepLink: deepLink
            )))
        }

        return entries
            .sorted { ($0.order, $0.item.title) < ($1.order, $1.item.title) }
            .prefix(favoritesLimit)
            .map(\.item)
    }
}
