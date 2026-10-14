//
//  WidgetSnapshotExporter.swift
//  Lume
//
//  Builds the `WidgetSnapshot` the tvOS Top Shelf renders, and writes it to
//  the shared App Group container. Extensions never query the catalog
//  themselves — SwiftData stays app-only and the extension reads a small
//  precomputed file instead (the reliable pattern for widget data).
//
//  The snapshot is the rows the user promoted (`TopShelfSettings.sources`),
//  each a copy of a Home, Movies or Series row. Local rows — Continue
//  Watching, Watch Again, Favorites, Recently Added — are built fresh here for
//  their surface, off the main actor on their own `ModelContext`. List rows
//  and For You come from the network or the recommender, so they show what
//  the app last loaded (`TopShelfSettings.recordedItems`). Every row follows
//  Home's visibility rules: categories hidden in Content Management, hidden
//  channels, and restricted categories for a child profile.
//
//  Exported on tvOS only, the one platform that ships an extension reading
//  the snapshot (`LumeTopShelf`), and only while the profile the Top Shelf
//  follows is active. Building it is platform-neutral, for tests.
//

import Foundation
import OSLog
import SwiftData
#if os(tvOS)
    import TVServices
#endif

/// One promoted row as the export needs it: what it is, what the Top Shelf
/// calls it, and — for a list row — the titles it last showed in the app.
nonisolated struct TopShelfRowPlan: Equatable {
    let source: TopShelfSource
    let title: String
    let recordedItems: [String]
}

enum WidgetSnapshotExporter {
    /// Every row holds as many items as the largest Top Shelf choice shows.
    private nonisolated static let limit = TopShelfConfiguration.maxItemsPerSection

    /// The promoted rows, gathered on the main actor where the layout
    /// settings live. A custom row since deleted drops out; two rows that
    /// share a name ("Favorites" on Home and on Movies) are told apart by
    /// their area.
    static func plan(defaults: UserDefaults = .standard) -> [TopShelfRowPlan] {
        let rows = TopShelfSettings.sources(defaults: defaults).compactMap { source -> (TopShelfSource, String)? in
            switch source.ref {
            case let .builtin(section):
                return (source, section.displayName)
            case let .custom(id):
                let raw = defaults.string(forKey: CustomHomeSections.storageKey(source.surface)) ?? ""
                return CustomHomeSections.decode(raw).first { $0.id == id }.map { (source, $0.title) }
            }
        }
        let counts = Dictionary(rows.map { ($0.1, 1) }, uniquingKeysWith: +)
        return rows.map { source, title in
            TopShelfRowPlan(
                source: source,
                title: counts[title, default: 0] > 1 ? "\(source.surface.displayName) · \(title)" : title,
                recordedItems: TopShelfSettings.recordedItems(for: source, defaults: defaults)
            )
        }
    }

    /// Rebuilds the snapshot off the main actor: a handful of bounded fetches,
    /// cheap enough for every launch, backgrounding and settings change. Held
    /// under a background-task assertion so a backgrounding export finishes
    /// instead of being suspended mid-write.
    static func refresh(container: ModelContainer, isChildProfile: Bool) {
        #if os(tvOS)
            let rows = plan()
            Task {
                await BackgroundActivity.perform("Top Shelf snapshot") {
                    await Task.detached(priority: .utility) {
                        export(container: container, rows: rows, isChildProfile: isChildProfile)
                    }.value
                }
            }
        #endif
    }

    /// Exports a fresh snapshot for the active playlist and tells the Top
    /// Shelf to re-read it. With no profile followed the Top Shelf is off,
    /// and an empty snapshot puts the app's artwork back. Otherwise a no-op
    /// unless the followed profile is active: the catalog holds only the
    /// active profile's watch state, so another profile's export would be
    /// wrong. The last snapshot stays.
    nonisolated static func export(
        container: ModelContainer,
        rows: [TopShelfRowPlan],
        isChildProfile: Bool,
        now: Date = Date()
    ) {
        var snapshot: WidgetSnapshot
        if TopShelfSettings.followedProfile() == nil {
            snapshot = WidgetSnapshot(generatedAt: now, sections: [])
        } else if TopShelfSettings.followsActiveProfile() {
            let storedID = UserDefaults.standard.string(forKey: PlaylistSelectionStore.key) ?? ""
            snapshot = makeSnapshot(
                container: container,
                rows: rows,
                storedPlaylistID: storedID,
                isChildProfile: isChildProfile,
                now: now
            )
        } else {
            Logger.database.info("Top Shelf export skipped: it follows another profile")
            return
        }
        snapshot.topShelf = TopShelfSettings.configuration()
        do {
            try WidgetDataStore.save(snapshot)
        } catch {
            Logger.database.error("Top Shelf snapshot export failed: \(error.localizedDescription, privacy: .public)")
            return
        }
        let counts = snapshot.sections.map { "\($0.id)=\($0.items.count)" }.joined(separator: ", ")
        Logger.database.info("Top Shelf snapshot written: \(snapshot.sections.count) rows [\(counts, privacy: .public)]")
        #if os(tvOS)
            TVTopShelfContentProvider.topShelfContentDidChange()
        #endif
    }

    /// The `HomeMediaItem.id` form a list row's titles are recorded in.
    static func itemKey(_ item: HomeMediaItem) -> String {
        item.id
    }

    /// Builds the snapshot for the active playlist. Hidden categories and
    /// channels never enter it, and restricted categories stay out while a
    /// child profile is active — the Top Shelf must not leak content the app
    /// hides. Internal (not private) so tests can build snapshots without
    /// touching the App Group container.
    nonisolated static func makeSnapshot(
        container: ModelContainer,
        rows: [TopShelfRowPlan],
        storedPlaylistID: String,
        isChildProfile: Bool,
        now: Date = Date()
    ) -> WidgetSnapshot {
        let context = ModelContext(container)
        let playlists = (try? context.fetch(FetchDescriptor<Playlist>())) ?? []
        guard let playlist = playlists.active(for: storedPlaylistID), !rows.isEmpty else {
            return WidgetSnapshot(generatedAt: now, sections: [])
        }
        let scope = Scope(
            context: context,
            container: container,
            prefix: "\(playlist.id.uuidString)-",
            restriction: ContentRestriction(
                isActive: isChildProfile,
                restrictedCategoryIDs: isChildProfile ? categoryIDs(in: context, matching: #Predicate { $0.isRestricted }) : [],
                hiddenCategoryIDs: categoryIDs(in: context, matching: #Predicate { $0.isHidden })
            )
        )
        return WidgetSnapshot(
            generatedAt: now,
            sections: rows.map { row in
                WidgetSection(id: row.source.token, title: row.title, items: items(for: row, in: scope))
            }
        )
    }

    /// What every row's fetch is narrowed to: the active playlist, under the
    /// viewer's visibility rules.
    private nonisolated struct Scope {
        let context: ModelContext
        let container: ModelContainer
        let prefix: String
        let restriction: ContentRestriction

        func shows(_ id: String, category: String?) -> Bool {
            id.hasPrefix(prefix) && !restriction.hides(categoryID: category)
        }
    }

    private nonisolated static func categoryIDs(
        in context: ModelContext,
        matching predicate: Predicate<Category>
    ) -> Set<String> {
        let categories = (try? context.fetch(FetchDescriptor<Category>(predicate: predicate))) ?? []
        return Set(categories.map(\.id))
    }

    private nonisolated static func items(for row: TopShelfRowPlan, in scope: Scope) -> [WidgetMediaItem] {
        let surface = row.source.surface
        let items: [WidgetMediaItem] = switch row.source.ref {
        case .builtin(.continueWatching): continueWatching(surface, in: scope)
        case .builtin(.recentlyWatched): watchAgain(surface, in: scope)
        case .builtin(.favorites): favorites(surface, in: scope)
        case .builtin(.recentlyAdded): recentlyAdded(surface, in: scope)
        case .builtin, .custom: recorded(row.recordedItems, in: scope)
        }
        return Array(items.prefix(limit))
    }

    // MARK: - Continue Watching

    /// Resumable titles, most recently watched first: partially watched movies
    /// and the in-progress episode of each show, plus — on Home, which mixes
    /// everything — channels watched lately.
    private nonisolated static func continueWatching(_ surface: SectionSurface, in scope: Scope) -> [WidgetMediaItem] {
        var entries: [(date: Date, item: WidgetMediaItem)] = []
        if surface != .series {
            var descriptor = FetchDescriptor<Movie>(
                predicate: #Predicate { $0.lastWatchedDate != nil && !$0.isWatched && $0.watchProgress > 0 },
                sortBy: [SortDescriptor(\.lastWatchedDate, order: .reverse)]
            )
            descriptor.fetchLimit = 60
            for movie in (try? scope.context.fetch(descriptor)) ?? [] where scope.shows(movie.id, category: movie.categoryId) {
                guard let date = movie.lastWatchedDate, let item = item(movie, progress: true) else { continue }
                entries.append((date, item))
            }
        }
        if surface != .movies {
            entries += resumableEpisodes(in: scope)
        }
        if surface == .home {
            var descriptor = FetchDescriptor<LiveStream>(
                predicate: #Predicate { $0.lastWatchedDate != nil && $0.isHidden == false },
                sortBy: [SortDescriptor(\.lastWatchedDate, order: .reverse)]
            )
            descriptor.fetchLimit = limit
            for stream in (try? scope.context.fetch(descriptor)) ?? [] where scope.shows(stream.id, category: stream.categoryId) {
                guard let date = stream.lastWatchedDate, let item = item(stream) else { continue }
                entries.append((date, item))
            }
        }
        return entries.sorted { $0.date > $1.date }.map(\.item)
    }

    /// The most recently watched in-progress episode of each show, found the
    /// way `SeriesResumeLoader` finds it: one fetch over the indexed watch-state
    /// columns rather than faulting every recently watched show's `episodes`.
    private nonisolated static func resumableEpisodes(in scope: Scope) -> [(date: Date, item: WidgetMediaItem)] {
        var descriptor = FetchDescriptor<Episode>(
            predicate: #Predicate { $0.watchProgress > 0 && $0.isWatched == false }
        )
        descriptor.relationshipKeyPathsForPrefetching = [\.series]
        var newest: [String: Episode] = [:]
        for episode in (try? scope.context.fetch(descriptor)) ?? [] {
            guard let show = episode.series, scope.shows(show.id, category: show.categoryId) else { continue }
            let watched = episode.lastWatchedDate ?? .distantPast
            if let seen = newest[show.id], (seen.lastWatchedDate ?? .distantPast) >= watched { continue }
            newest[show.id] = episode
        }
        return newest.values.compactMap { episode in
            guard let show = episode.series,
                  let date = show.lastWatchedDate ?? episode.lastWatchedDate,
                  let deepLink = WidgetDeepLink.play(kind: .episode, id: episode.id) else { return nil }
            return (date, WidgetMediaItem(
                id: "episode-\(episode.id)",
                kind: .episode,
                title: show.name,
                subtitle: "S\(episode.seasonNum) E\(episode.episodeNum) · \(episode.title)",
                imageURL: URL(string: show.cover ?? episode.movieImage ?? ""),
                backdropURL: TMDBClient.backdropURL(show.backdropPath),
                progress: fraction(episode.watchProgress, of: episode.durationSecs),
                deepLink: deepLink,
                detailLink: WidgetDeepLink.openSeries(id: show.id)
            ))
        }
    }

    // MARK: - Watch Again

    /// Finished movies and series, most recently watched first — the split
    /// the Home and Series rails use (`ContinueWatchingLoader`).
    private nonisolated static func watchAgain(_ surface: SectionSurface, in scope: Scope) -> [WidgetMediaItem] {
        var entries: [(date: Date, item: WidgetMediaItem)] = []
        if surface != .series {
            var descriptor = FetchDescriptor<Movie>(
                predicate: #Predicate { $0.lastWatchedDate != nil && $0.isWatched == true },
                sortBy: [SortDescriptor(\.lastWatchedDate, order: .reverse)]
            )
            descriptor.fetchLimit = 60
            for movie in (try? scope.context.fetch(descriptor)) ?? [] where scope.shows(movie.id, category: movie.categoryId) {
                guard let date = movie.lastWatchedDate, let item = item(movie, progress: false) else { continue }
                entries.append((date, item))
            }
        }
        if surface != .movies {
            var descriptor = FetchDescriptor<Series>(
                predicate: #Predicate { $0.lastWatchedDate != nil },
                sortBy: [SortDescriptor(\.lastWatchedDate, order: .reverse)]
            )
            descriptor.fetchLimit = 60
            let shows = ((try? scope.context.fetch(descriptor)) ?? []).filter { scope.shows($0.id, category: $0.categoryId) }
            let finished = ContinueWatchingLoader.load(container: scope.container, series: shows.map(\.persistentModelID)).finished
            for show in shows where finished.contains(show.id) {
                guard let date = show.lastWatchedDate, let item = item(show) else { continue }
                entries.append((date, item))
            }
        }
        return entries.sorted { $0.date > $1.date }.map(\.item)
    }

    // MARK: - Favorites

    /// Favorites in the user's unified `favoriteOrder` (nil last, then by
    /// name — same as Home): movies, series and channels on Home, only the
    /// surface's own kind on Movies or Series.
    private nonisolated static func favorites(_ surface: SectionSurface, in scope: Scope) -> [WidgetMediaItem] {
        var entries: [(order: Int, item: WidgetMediaItem)] = []
        if surface != .series {
            for movie in (try? scope.context.fetch(FetchDescriptor<Movie>(predicate: #Predicate { $0.isFavorite }))) ?? []
                where scope.shows(movie.id, category: movie.categoryId)
            {
                if let item = item(movie, progress: false) { entries.append((movie.favoriteOrder ?? Int.max, item)) }
            }
        }
        if surface != .movies {
            for show in (try? scope.context.fetch(FetchDescriptor<Series>(predicate: #Predicate { $0.isFavorite }))) ?? []
                where scope.shows(show.id, category: show.categoryId)
            {
                if let item = item(show) { entries.append((show.favoriteOrder ?? Int.max, item)) }
            }
        }
        if surface == .home {
            let streams = (try? scope.context.fetch(
                FetchDescriptor<LiveStream>(predicate: #Predicate { $0.isFavorite && $0.isHidden == false })
            )) ?? []
            for stream in streams where scope.shows(stream.id, category: stream.categoryId) {
                if let item = item(stream) { entries.append((stream.favoriteOrder ?? Int.max, item)) }
            }
        }
        return entries
            .sorted { ($0.order, $0.item.title) < ($1.order, $1.item.title) }
            .map(\.item)
    }

    // MARK: - Recently Added

    /// The newest titles first, by the sort keys the Movies and Series rows
    /// use (`added` / `lastModified`, both indexed with the filter columns).
    private nonisolated static func recentlyAdded(_ surface: SectionSurface, in scope: Scope) -> [WidgetMediaItem] {
        switch surface {
        case .movies:
            var descriptor = FetchDescriptor<Movie>(
                predicate: #Predicate { $0.added != nil },
                sortBy: [SortDescriptor(\.added, comparator: .lexical, order: .reverse)]
            )
            descriptor.fetchLimit = 200
            return ((try? scope.context.fetch(descriptor)) ?? [])
                .filter { scope.shows($0.id, category: $0.categoryId) }
                .compactMap { item($0, progress: false) }
        case .series:
            var descriptor = FetchDescriptor<Series>(
                predicate: #Predicate { $0.lastModified != nil },
                sortBy: [SortDescriptor(\.lastModified, comparator: .lexical, order: .reverse)]
            )
            descriptor.fetchLimit = 200
            return ((try? scope.context.fetch(descriptor)) ?? [])
                .filter { scope.shows($0.id, category: $0.categoryId) }
                .compactMap(item)
        case .home:
            return []
        }
    }

    // MARK: - List rows

    /// The titles a list row (trending, a watchlist, a custom list, For You)
    /// last showed in the app, in order — see `TopShelfSettings.record`.
    private nonisolated static func recorded(_ keys: [String], in scope: Scope) -> [WidgetMediaItem] {
        keys.compactMap { key in
            guard let separator = key.firstIndex(of: "-") else { return nil }
            let kind = key[..<separator]
            let id = String(key[key.index(after: separator)...])
            switch kind {
            case "movie":
                guard let movie = first(Movie.self, #Predicate { $0.id == id }, in: scope.context),
                      scope.shows(movie.id, category: movie.categoryId) else { return nil }
                return item(movie, progress: false)
            case "series":
                guard let show = first(Series.self, #Predicate { $0.id == id }, in: scope.context),
                      scope.shows(show.id, category: show.categoryId) else { return nil }
                return item(show)
            case "live":
                guard let stream = first(LiveStream.self, #Predicate { $0.id == id && $0.isHidden == false }, in: scope.context),
                      scope.shows(stream.id, category: stream.categoryId) else { return nil }
                return item(stream)
            default:
                return nil
            }
        }
    }

    private nonisolated static func first<Model: PersistentModel>(
        _: Model.Type, _ predicate: Predicate<Model>, in context: ModelContext
    ) -> Model? {
        var descriptor = FetchDescriptor<Model>(predicate: predicate)
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }

    // MARK: - Items

    private nonisolated static func item(_ movie: Movie, progress: Bool) -> WidgetMediaItem? {
        guard let deepLink = WidgetDeepLink.play(kind: .movie, id: movie.id) else { return nil }
        return WidgetMediaItem(
            id: "movie-\(movie.id)",
            kind: .movie,
            title: movie.name,
            subtitle: movie.releaseDate,
            imageURL: URL(string: movie.streamIcon ?? ""),
            backdropURL: TMDBClient.backdropURL(movie.backdropPath),
            progress: progress ? fraction(movie.watchProgress, of: movie.durationSecs) : nil,
            deepLink: deepLink,
            detailLink: WidgetDeepLink.openMovie(id: movie.id)
        )
    }

    private nonisolated static func item(_ show: Series) -> WidgetMediaItem? {
        guard let deepLink = WidgetDeepLink.openSeries(id: show.id) else { return nil }
        return WidgetMediaItem(
            id: "series-\(show.id)",
            kind: .series,
            title: show.name,
            subtitle: nil,
            imageURL: URL(string: show.cover ?? ""),
            backdropURL: TMDBClient.backdropURL(show.backdropPath),
            progress: nil,
            deepLink: deepLink,
            detailLink: deepLink
        )
    }

    private nonisolated static func item(_ stream: LiveStream) -> WidgetMediaItem? {
        guard let deepLink = WidgetDeepLink.play(kind: .live, id: stream.id) else { return nil }
        return WidgetMediaItem(
            id: "live-\(stream.id)",
            kind: .live,
            title: stream.name,
            subtitle: nil,
            imageURL: URL(string: stream.streamIcon ?? ""),
            progress: nil,
            deepLink: deepLink
        )
    }

    private nonisolated static func fraction(_ position: Double, of duration: Int?) -> Double? {
        guard let duration, duration > 0 else { return nil }
        return min(position / Double(duration), 1)
    }
}
