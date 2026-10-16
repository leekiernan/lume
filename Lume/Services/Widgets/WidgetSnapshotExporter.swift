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
//  the snapshot (`LumeTopShelf`), through `TopShelfRefresher`, and only while
//  the profile the Top Shelf follows is active. Building it is
//  platform-neutral, for tests.
//

import Foundation
import OSLog
import SwiftData
#if os(tvOS)
    import TVServices
#endif

/// The profile an export is for, captured on the main actor with its child
/// flag so the two can't come from different profiles.
nonisolated struct TopShelfExportRequest: Equatable {
    let profileID: UUID
    let isChildProfile: Bool
}

/// One promoted row as the export needs it: what it is, what the Top Shelf
/// calls it, and — for a list row — the titles it last showed in the app.
nonisolated struct TopShelfRowPlan: Equatable {
    let source: TopShelfSource
    let title: String
    let recordedItems: [String]

    /// The row as the layout defines it — which row and what it's called —
    /// without the titles it last recorded, which change whenever a feed
    /// loads.
    struct Layout: Hashable {
        let source: TopShelfSource
        let title: String
    }

    var layout: Layout {
        Layout(source: source, title: title)
    }

    /// Whether an export planned from `planned` may still publish against
    /// `current`: the same rows, named the same, in the same order. Recorded
    /// titles don't count — feeds record as they load, and comparing them
    /// would discard an export whenever a row finished loading mid-export.
    static func sameLayout(_ planned: [Self], _ current: [Self]) -> Bool {
        planned.map(\.layout) == current.map(\.layout)
    }
}

/// Capture settings once, rather than mixing the enqueue-time rows with
/// profile or layout values read later on a background task.
nonisolated struct TopShelfExportInput: Equatable {
    let request: TopShelfExportRequest
    let followed: UUID?
    let playlistID: String
    let rows: [TopShelfRowPlan]
    let configuration: TopShelfConfiguration
}

enum WidgetSnapshotExporter {
    /// Every row holds as many items as the largest Top Shelf choice shows.
    private nonisolated static let limit = TopShelfConfiguration.maxItemsPerSection

    /// The promoted rows, gathered on the main actor where the layout
    /// settings live. A custom row since deleted drops out; two rows that
    /// share a name ("Favorites" on Home and on Movies) are told apart by
    /// their area.
    static func plan(defaults: UserDefaults = .standard) -> [TopShelfRowPlan] {
        let rows = TopShelfSettings.sources(defaults: defaults).compactMap { source in
            source.rowName(defaults: defaults).map { (source, $0) }
        }
        let counts = Dictionary(rows.map { ($0.1, 1) }, uniquingKeysWith: +)
        let followed = TopShelfSettings.followedProfile(defaults: defaults)
        return rows.map { source, name in
            TopShelfRowPlan(
                source: source,
                title: counts[name, default: 0] > 1 ? source.qualified(name) : name,
                recordedItems: TopShelfSettings.recordedItems(for: source, profile: followed, defaults: defaults)
            )
        }
    }

    /// Writes the snapshot `TopShelfSettings.exportAction` calls for and tells
    /// the Top Shelf to re-read it. `request` is the profile that was active
    /// when the export was asked for, with its child flag: the catalog holds
    /// only the active profile's watch state, so rows are built only when the
    /// request is for the followed profile and that profile is still active.
    /// Run by `TopShelfRefresher`, one export at a time.
    nonisolated static func export(
        container: ModelContainer,
        input: TopShelfExportInput,
        canPublish: @escaping @MainActor @Sendable () -> Bool,
        now: Date = Date()
    ) async {
        guard !Task.isCancelled else { return }
        let request = input.request
        let followed = input.followed
        var snapshot: WidgetSnapshot
        switch TopShelfSettings.exportAction(
            followed: followed,
            active: request.profileID,
            snapshotProfile: TopShelfSettings.snapshotProfile()
        ) {
        case .keep:
            return
        case .clear:
            snapshot = WidgetSnapshot(generatedAt: now, sections: [])
        case .build:
            // A switch may have landed since the request: its child flag
            // would then describe the wrong profile.
            guard ActiveProfileStore.current == request.profileID else {
                Logger.database.info("Top Shelf export skipped: the profile changed since it was asked for")
                return
            }
            snapshot = makeSnapshot(
                container: container,
                rows: input.rows,
                storedPlaylistID: input.playlistID,
                isChildProfile: request.isChildProfile,
                now: now
            )
        }
        snapshot.topShelf = input.configuration
        let owner = snapshot.sections.isEmpty ? nil : followed
        #if os(tvOS)
            // The carousel's art, with each title's logo drawn in, is rendered
            // here rather than in the extension — see `TopShelfCarouselArt`.
            // What's already rendered goes out with the snapshot; the rest
            // follows in a second write once it has rendered.
            let carousel = snapshot.topShelf?.style == .carousel
            if carousel { TopShelfCarouselArt.applyCached(to: &snapshot) }
            guard await publish(snapshot, owner: owner, canPublish: canPublish) else { return }
            if carousel, await TopShelfCarouselArt.renderMissing(in: &snapshot) {
                guard await publish(snapshot, owner: owner, canPublish: canPublish) else { return }
            }
            guard !Task.isCancelled, await canPublish() else { return }
            TopShelfCarouselArt.prune(keeping: carousel ? snapshot : WidgetSnapshot(generatedAt: now, sections: []))
        #else
            _ = await publish(snapshot, owner: owner, canPublish: canPublish)
        #endif
    }

    /// Validation and publication share the main actor with settings changes,
    /// so an obsolete render cannot write after a newer request invalidates it.
    private static func publish(_ snapshot: WidgetSnapshot, owner: UUID?, canPublish: @MainActor () -> Bool) -> Bool {
        guard !Task.isCancelled, canPublish() else {
            Logger.database.info("Top Shelf export superseded before publishing")
            return false
        }
        return write(snapshot, owner: owner)
    }

    /// Saves the snapshot unless it shows what the one on disk already does:
    /// every backgrounding asks for an export, and an unchanged one would
    /// still make the Top Shelf reload its images.
    private nonisolated static func write(_ snapshot: WidgetSnapshot, owner: UUID?) -> Bool {
        if let current = WidgetDataStore.load(), current.sections == snapshot.sections, current.topShelf == snapshot.topShelf {
            TopShelfSettings.setSnapshotProfile(owner)
            return true
        }
        do {
            try WidgetDataStore.save(snapshot)
        } catch {
            Logger.database.error("Top Shelf snapshot export failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
        TopShelfSettings.setSnapshotProfile(owner)
        let counts = snapshot.sections.map { "\($0.id)=\($0.items.count)" }.joined(separator: ", ")
        Logger.database.info("Top Shelf snapshot written: \(snapshot.sections.count) rows [\(counts, privacy: .public)]")
        #if os(tvOS)
            TVTopShelfContentProvider.topShelfContentDidChange()
        #endif
        return true
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
    /// viewer's visibility rules. A class so the series split, which both
    /// watch rows read, is worked out once per export.
    private final nonisolated class Scope {
        let context: ModelContext
        let container: ModelContainer
        let prefix: String
        let restriction: ContentRestriction

        init(context: ModelContext, container: ModelContainer, prefix: String, restriction: ContentRestriction) {
            self.context = context
            self.container = container
            self.prefix = prefix
            self.restriction = restriction
        }

        func shows(_ id: String, category: String?) -> Bool {
            id.hasPrefix(prefix) && !restriction.hides(categoryID: category)
        }

        var excludedCategories: Set<String?> {
            Set(restriction.excludedCategoryIDs.map(String?.some))
        }

        /// The recently watched shows, most recent first, and where each
        /// continues — the split the Home and Series rails make
        /// (`ContinueWatchingLoader`): a show with an episode to go is in
        /// Continue Watching, one with none left is in Watch Again.
        private(set) lazy var watchedSeries: (shows: [Series], split: ContinueWatchingLoader.Result) = {
            let prefix = self.prefix
            let excluded = excludedCategories
            var descriptor = FetchDescriptor<Series>(
                predicate: #Predicate {
                    $0.lastWatchedDate != nil && $0.id.starts(with: prefix)
                        && ($0.categoryId == nil || !excluded.contains($0.categoryId))
                },
                sortBy: [SortDescriptor(\.lastWatchedDate, order: .reverse)]
            )
            // Both rows together never show more than this many shows.
            descriptor.fetchLimit = WidgetSnapshotExporter.limit * 2
            let shows = ((try? context.fetch(descriptor)) ?? []).filter { shows($0.id, category: $0.categoryId) }
            return (shows, ContinueWatchingLoader.load(container: container, series: shows.map(\.persistentModelID)))
        }()
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
    /// and each show with an episode to go, plus — on Home, which mixes
    /// everything — channels watched lately.
    private nonisolated static func continueWatching(_ surface: SectionSurface, in scope: Scope) -> [WidgetMediaItem] {
        var entries: [(date: Date, item: WidgetMediaItem)] = []
        let prefix = scope.prefix
        let excluded = scope.excludedCategories
        if surface != .series {
            var descriptor = FetchDescriptor<Movie>(
                predicate: #Predicate {
                    $0.lastWatchedDate != nil && !$0.isWatched && $0.watchProgress > 0
                        && $0.id.starts(with: prefix) && ($0.categoryId == nil || !excluded.contains($0.categoryId))
                },
                sortBy: [SortDescriptor(\.lastWatchedDate, order: .reverse)]
            )
            descriptor.fetchLimit = limit * 2
            for movie in (try? scope.context.fetch(descriptor)) ?? [] where scope.shows(movie.id, category: movie.categoryId) {
                guard let date = movie.lastWatchedDate, let item = item(movie, progress: true) else { continue }
                entries.append((date, item))
            }
        }
        if surface != .movies {
            let (shows, split) = scope.watchedSeries
            for show in shows where !split.finished.contains(show.id) {
                guard let date = show.lastWatchedDate, let item = item(show, continuingAt: split.continuations[show.id]) else { continue }
                entries.append((date, item))
            }
        }
        if surface == .home {
            var descriptor = FetchDescriptor<LiveStream>(
                predicate: #Predicate {
                    $0.lastWatchedDate != nil && $0.isHidden == false
                        && $0.id.starts(with: prefix) && ($0.categoryId == nil || !excluded.contains($0.categoryId))
                },
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

    // MARK: - Watch Again

    /// Finished movies and series, most recently watched first — the split
    /// the Home and Series rails use (`ContinueWatchingLoader`).
    private nonisolated static func watchAgain(_ surface: SectionSurface, in scope: Scope) -> [WidgetMediaItem] {
        var entries: [(date: Date, item: WidgetMediaItem)] = []
        let prefix = scope.prefix
        let excluded = scope.excludedCategories
        if surface != .series {
            var descriptor = FetchDescriptor<Movie>(
                predicate: #Predicate {
                    $0.lastWatchedDate != nil && $0.isWatched == true
                        && $0.id.starts(with: prefix) && ($0.categoryId == nil || !excluded.contains($0.categoryId))
                },
                sortBy: [SortDescriptor(\.lastWatchedDate, order: .reverse)]
            )
            descriptor.fetchLimit = limit * 2
            for movie in (try? scope.context.fetch(descriptor)) ?? [] where scope.shows(movie.id, category: movie.categoryId) {
                guard let date = movie.lastWatchedDate, let item = item(movie, progress: false) else { continue }
                entries.append((date, item))
            }
        }
        if surface != .movies {
            let (shows, split) = scope.watchedSeries
            for show in shows where split.finished.contains(show.id) {
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
        // The playlist is in the predicate, so other playlists' newer titles
        // can't fill the fetch and leave this row short.
        let prefix = scope.prefix
        let excluded = scope.excludedCategories
        switch surface {
        case .movies:
            var descriptor = FetchDescriptor<Movie>(
                predicate: #Predicate {
                    $0.added != nil && $0.id.starts(with: prefix)
                        && ($0.categoryId == nil || !excluded.contains($0.categoryId))
                },
                sortBy: [SortDescriptor(\.added, comparator: .lexical, order: .reverse)]
            )
            descriptor.fetchLimit = limit * 4
            return ((try? scope.context.fetch(descriptor)) ?? [])
                .filter { scope.shows($0.id, category: $0.categoryId) }
                .compactMap { item($0, progress: false) }
        case .series:
            var descriptor = FetchDescriptor<Series>(
                predicate: #Predicate {
                    $0.lastModified != nil && $0.id.starts(with: prefix)
                        && ($0.categoryId == nil || !excluded.contains($0.categoryId))
                },
                sortBy: [SortDescriptor(\.lastModified, comparator: .lexical, order: .reverse)]
            )
            descriptor.fetchLimit = limit * 4
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
        keys.compactMap { raw in
            guard let key = MediaItemKey(raw) else { return nil }
            let id = key.id
            switch key.kind {
            case .movie:
                guard let movie = first(Movie.self, #Predicate { $0.id == id }, in: scope.context),
                      scope.shows(movie.id, category: movie.categoryId) else { return nil }
                return item(movie, progress: false)
            case .series:
                guard let show = first(Series.self, #Predicate { $0.id == id }, in: scope.context),
                      scope.shows(show.id, category: show.categoryId) else { return nil }
                return item(show)
            case .live:
                guard let stream = first(LiveStream.self, #Predicate { $0.id == id && $0.isHidden == false }, in: scope.context),
                      scope.shows(stream.id, category: stream.categoryId) else { return nil }
                return item(stream)
            case .episode:
                // Rows record rail items (`HomeMediaItem`), never episodes.
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

    /// The carousel draws a logo about a third of its width: enough at this
    /// size, where the hero's `original` would be a large download for an
    /// extension.
    private nonisolated static let topShelfLogoSize: TMDBLogoSize = .w500

    private nonisolated static func item(_ movie: Movie, progress: Bool) -> WidgetMediaItem? {
        guard let deepLink = WidgetDeepLink.play(kind: .movie, id: movie.id) else { return nil }
        return WidgetMediaItem(
            id: MediaItemKey.movie(movie.id).description,
            kind: .movie,
            title: movie.name,
            subtitle: movie.releaseDate,
            imageURL: URL(string: movie.streamIcon ?? ""),
            backdropURL: TMDBClient.backdropURL(movie.backdropPath),
            progress: progress ? fraction(movie.watchProgress, of: movie.durationSecs) : nil,
            deepLink: deepLink,
            detailLink: WidgetDeepLink.openMovie(id: movie.id),
            logoURL: TMDBClient.logoURL(movie.logoPath, size: topShelfLogoSize)
        )
    }

    private nonisolated static func item(_ show: Series) -> WidgetMediaItem? {
        guard let deepLink = WidgetDeepLink.openSeries(id: show.id) else { return nil }
        return WidgetMediaItem(
            id: MediaItemKey.series(show.id).description,
            kind: .series,
            title: show.name,
            subtitle: nil,
            imageURL: URL(string: show.cover ?? ""),
            backdropURL: TMDBClient.backdropURL(show.backdropPath),
            progress: nil,
            deepLink: deepLink,
            detailLink: deepLink,
            logoURL: TMDBClient.logoURL(show.logoPath, size: topShelfLogoSize)
        )
    }

    /// A show in Continue Watching: plays the episode it continues with, as
    /// the rail's card does, under the rail's "S7, E12 · 32m left" label. A
    /// show whose episodes this device hasn't loaded yet has no continuation
    /// and opens its page instead.
    private nonisolated static func item(_ show: Series, continuingAt continuation: SeriesContinuation?) -> WidgetMediaItem? {
        guard let continuation else { return item(show) }
        let episode = show.episodes.first { $0.seasonNum == continuation.season && $0.episodeNum == continuation.episode }
        guard let episode, let deepLink = WidgetDeepLink.play(kind: .episode, id: episode.id) else { return item(show) }
        return WidgetMediaItem(
            id: MediaItemKey.episode(episode.id).description,
            kind: .episode,
            title: show.name,
            subtitle: ContinueWatching.seriesLabel(continuation),
            imageURL: URL(string: show.cover ?? episode.movieImage ?? ""),
            backdropURL: TMDBClient.backdropURL(show.backdropPath),
            progress: continuation.fraction.flatMap { $0 > 0 ? $0 : nil },
            deepLink: deepLink,
            detailLink: WidgetDeepLink.openSeries(id: show.id),
            logoURL: TMDBClient.logoURL(show.logoPath, size: topShelfLogoSize)
        )
    }

    private nonisolated static func item(_ stream: LiveStream) -> WidgetMediaItem? {
        guard let deepLink = WidgetDeepLink.play(kind: .live, id: stream.id) else { return nil }
        return WidgetMediaItem(
            id: MediaItemKey.live(stream.id).description,
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
