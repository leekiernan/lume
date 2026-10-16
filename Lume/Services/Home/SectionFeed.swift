//
//  SectionFeed.swift
//  Lume
//
//  The remote-backed rows shared by every section surface (Home, Movies,
//  Series): TMDB trending, the Trakt/Simkl watchlists, and the user's custom list
//  rows. Each surface owns one `SectionFeed`; the locally-queried rows
//  (Recently Watched, Favorites, Recently Added) stay as @Query-backed views.
//
//  Everything here matches remote titles against the local catalog by TMDB id
//  in batched queries, so a row only ever shows titles the active playlist
//  actually carries. `surface.mediaType` narrows that to one medium on the
//  Movies and Series pages — a movie list added there simply resolves to
//  nothing on the Series page rather than showing the wrong medium.
//

import OSLog
import SwiftData
import SwiftUI

@MainActor
@Observable
final class SectionFeed {
    private typealias CacheRestore = SectionFeedLoadMachine.CacheHit

    /// What a load needs from the view: the store to match against, the
    /// viewer's hidden categories, and the active playlist's id prefix (nil
    /// means "no playlist scoping", which is what previews get).
    struct Context {
        let modelContext: ModelContext
        let restriction: ContentRestriction
        let playlistPrefix: String?
        let profileID: UUID?

        init(modelContext: ModelContext, restriction: ContentRestriction, playlistPrefix: String?, profileID: UUID? = ActiveProfileStore.current) {
            self.modelContext = modelContext
            self.restriction = restriction
            self.playlistPrefix = playlistPrefix
            self.profileID = profileID
        }

        func belongsToActivePlaylist(_ id: String) -> Bool {
            guard let playlistPrefix else { return true }
            return id.hasPrefix(playlistPrefix)
        }
    }

    let surface: SectionSurface

    /// Which row the surface shows as its hero, set from its stored preference
    /// before each load. Nothing stands in for it while that row loads, so the
    /// hero opens on its own content or on nothing, never on someone else's.
    var heroRef: HomeSectionRef?
    /// Bumped when hero artwork lands — see `refreshHeroArtwork`.
    var heroArtworkRevision = 0
    /// Fresh TMDB paths used immediately while the view context still holds the
    /// pre-enrichment version of a model. The same details are persisted by the
    /// enrichment actor for subsequent launches.
    var heroPresentationOverrides: [String: HeroPresentation] = [:]
    /// Prevents the independent trending, watchlist and custom-section loaders
    /// from requesting the same hero enrichment while another loader is still
    /// waiting for it.
    var heroEnrichmentIDs: Set<String> = []
    /// Every remote-backed row shares one representation: its lightweight
    /// ordered source plus a bounded catalog preview. The source tail remains
    /// available for an incrementally-loaded full grid without keeping all of
    /// its SwiftData models alive on the browse screen.
    private(set) var collections: [HomeSectionRef: SectionCollectionSnapshot] = [:]

    /// Every source's load state and the catalog scope they were matched in —
    /// see `SectionFeedLoadMachine`. Only `transition(_:)` advances it.
    private(set) var loads = SectionFeedLoadMachine()
    /// The custom sections last asked for, so a scope change can reload them.
    var requestedCustomSections: [CustomHomeSection] = []
    let listCache: HomeListCache
    let fetchListPage: @Sendable (String, Int) async throws -> HomeListPage
    let loadGate = SectionFeedLoadGate()
    var context: Context?
    var loadPlan: SectionFeedLoadPlan?
    var heroLoadStarted: ContinuousClock.Instant?

    func recordHeroReadiness() {
        guard !heroItems.isEmpty, let started = heroLoadStarted else { return }
        heroLoadStarted = nil
        Logger.home.info("\(surface.rawValue) hero data ready after \(String(describing: started.duration(to: .now)), privacy: .public); source=\(heroRef?.token ?? "none", privacy: .public)")
    }

    /// How many matched titles a remote-backed row shows.
    static let itemLimit = 20
    /// How many hero candidates the Home carousel pages through.
    static let heroLimit = 8

    init(surface: SectionSurface, listCache: HomeListCache = .shared,
         fetchListPage: @escaping @Sendable (String, Int) async throws -> HomeListPage = { try await HomeListCatalog.page(for: $0, number: $1) })
    {
        self.surface = surface
        self.listCache = listCache
        self.fetchListPage = fetchListPage
    }

    func items(for section: HomeSectionRef) -> [HomeMediaItem] {
        collections[section]?.preview ?? []
    }

    /// The hero's titles when it is a local row (Continue Watching, Favorites,
    /// Recently Added…). Only the page holds those rows' queries, so it hands
    /// their items in; a list row's come from `collections` instead.
    private(set) var localHeroItems: [HomeMediaItem] = []

    /// Hands the page's local hero titles in, ignoring an unchanged set.
    func setLocalHeroItems(_ items: [HomeMediaItem]) {
        guard items.map(\.id) != localHeroItems.map(\.id) else { return }
        localHeroItems = items
    }

    private var heroSourceItems: [HomeMediaItem] {
        guard let heroRef else { return [] }
        return SectionFeedSource(row: heroRef) == nil ? localHeroItems : items(for: heroRef)
    }

    func collection(for section: HomeSectionRef) -> SectionCollectionSnapshot? {
        collections[section]
    }

    func isRefreshing(_ section: HomeSectionRef) -> Bool {
        let state = loads.state(of: section)
        return state == .loading || state == .cached
    }

    /// The promoted row's titles, as hero slides. Titles whose backdrop hasn't
    /// been fetched yet are held back rather than shown as a stretched poster;
    /// `refreshHeroArtwork` fills them in and they appear on the next pass.
    var heroItems: [HeroItem] {
        // Observed so the hero recomputes once enrichment fills in backdrops.
        _ = heroArtworkRevision
        return heroCandidates
            .filter(\.hasWideArtwork)
            .prefix(Self.heroLimit)
            .map(\.self)
    }

    /// Everything the promoted row resolved to, artwork or not.
    var heroCandidates: [HeroItem] {
        heroSourceItems.compactMap { item in
            let presentation = heroPresentationOverrides[item.id]
            return HeroItem(
                item: item,
                backdropPath: presentation?.backdropPath,
                posterPath: presentation?.posterPath,
                logoPath: presentation?.logoPath,
                overview: presentation?.overview
            )
        }
    }

    /// True once every remote row has settled, so a surface can tell "still
    /// loading" from "genuinely empty" before showing an empty state.
    var isSettled: Bool {
        loads.isSettled
    }

    /// The hero's explicit UI state. Views reserve its large first-frame slot
    /// only while this says it may still produce content; a terminal empty or
    /// failed source lets the rows move up instead of leaving a blank expanse.
    var heroState: HeroLoadState {
        loads.heroState(
            for: heroRef,
            hasSlides: !heroItems.isEmpty,
            rowHasItems: !heroSourceItems.isEmpty
        )
    }

    // MARK: - Trending

    func loadTrending(cacheKey: String) async {
        let request = loadGate.begin(.trending)
        let cached = restoreTrending(cacheKey: cacheKey)
        transition(.began(.trending, key: cacheKey, cache: cached))
        if cached == .fresh {
            await refreshHeroArtwork()
            guard loadGate.isCurrent(request, for: .trending) else { return }
            transition(.rowsRecovered([.builtin(.trendingMovies), .builtin(.trendingSeries)]))
            transition(.finished(.trending, .loaded))
            return
        }
        guard let context else {
            finishTrendingFailure(cached: cached)
            return
        }
        let client = TMDBClient.shared
        guard client.isConfigured else {
            finishTrendingFailure(cached: cached)
            return
        }
        let interval = Perf.begin(.homeTrendingLoad)
        defer { Perf.end(interval) }
        do {
            try await refreshTrending(client: client, context: context, cacheKey: cacheKey, request: request)
        } catch {
            guard loadGate.isCurrent(request, for: .trending) else { return }
            finishTrendingFailure(cached: cached)
        }
    }

    private func refreshTrending(
        client: TMDBClient,
        context: Context,
        cacheKey: String,
        request: SectionFeedLoadGate.Request
    ) async throws {
        let (movies, tvSeries) = try await trendingTitles(using: client)
        guard loadGate.isCurrent(request, for: .trending) else { return }
        let movieCollection = await makeCollection(
            entries: movies.map { HomeListEntry(tmdbId: $0.id, mediaType: .movie, title: $0.title) },
            context: context
        )
        guard loadGate.isCurrent(request, for: .trending) else { return }
        let seriesCollection = await makeCollection(
            entries: tvSeries.map { HomeListEntry(tmdbId: $0.id, mediaType: .series, title: $0.title) },
            context: context
        )
        guard loadGate.isCurrent(request, for: .trending) else { return }
        collections[.builtin(.trendingMovies)] = requestsRow(.builtin(.trendingMovies)) ? movieCollection : .empty
        collections[.builtin(.trendingSeries)] = requestsRow(.builtin(.trendingSeries)) ? seriesCollection : .empty
        logMatch("trending movies", movieCollection)
        logMatch("trending series", seriesCollection)
        SectionFeedCache.shared.storeTrending(surface, key: scoped(cacheKey), entry: .init(
            movies: movieCollection,
            series: seriesCollection
        ))
        await refreshHeroArtwork()
        guard loadGate.isCurrent(request, for: .trending) else { return }
        transition(.rowsRecovered([.builtin(.trendingMovies), .builtin(.trendingSeries)]))
        transition(.finished(.trending, .loaded))
    }

    private func trendingTitles(using client: TMDBClient) async throws -> ([TrendingTitle], [TrendingTitle]) {
        // A scoped surface only ever renders one medium, so don't pay for the
        // other feed there.
        // Decided here: `async let` runs its expression off the main actor.
        let wantsMovies = surface.mediaType != .series && requestsRow(.builtin(.trendingMovies))
        let wantsSeries = surface.mediaType != .movie && requestsRow(.builtin(.trendingSeries))
        async let movieTitles = wantsMovies ? client.trending(.movie) : []
        async let tvTitles = wantsSeries ? client.trending(.tvShow) : []
        return try await (movieTitles, tvTitles)
    }

    private func restoreTrending(cacheKey: String) -> CacheRestore {
        guard let cached = SectionFeedCache.shared.trendingEntry(surface, for: scoped(cacheKey)) else { return .missing }
        collections[.builtin(.trendingMovies)] = requestsRow(.builtin(.trendingMovies)) ? cached.value.movies : .empty
        collections[.builtin(.trendingSeries)] = requestsRow(.builtin(.trendingSeries)) ? cached.value.series : .empty
        return cached.isFresh ? .fresh : .stale
    }

    private func finishTrendingFailure(cached: CacheRestore) {
        let refs: [HomeSectionRef] = [.builtin(.trendingMovies), .builtin(.trendingSeries)]
        for ref in refs where items(for: ref).isEmpty {
            transition(.rowsFailed([ref]))
        }
        let usable = cached != .missing && refs.contains(where: { !items(for: $0).isEmpty })
        transition(.finished(.trending, usable ? .loaded : .failed))
    }
}

// MARK: - Watchlist and custom sections

extension SectionFeed {
    /// Loads the connected user's watchlist from `provider` and keeps only the
    /// titles the user actually owns in the active playlist — matched by TMDB
    /// id, the same way the trending rows work, and narrowed to the surface's
    /// medium.
    func loadWatchlist(_ provider: WatchlistProvider, cacheKey: String) async {
        let ref = HomeSectionRef.builtin(provider.section)
        let feed = SectionFeedSource.watchlist(provider)
        let request = loadGate.begin(feed)
        let cached = restoreWatchlist(provider, cacheKey: cacheKey)
        transition(.began(feed, key: cacheKey, cache: cached))
        if cached == .fresh {
            await refreshHeroArtwork()
            guard loadGate.isCurrent(request, for: feed) else { return }
            transition(.rowsRecovered([ref]))
            transition(.finished(.watchlist(provider), .loaded))
            return
        }
        guard let context else {
            finishWatchlistFailure(provider, cached: cached)
            return
        }
        guard provider.isConnected else {
            collections[ref] = .empty
            transition(.rowsRecovered([ref]))
            transition(.finished(.watchlist(provider), .loaded))
            return
        }
        do {
            let entries = try await provider.entries()
            guard loadGate.isCurrent(request, for: feed) else { return }
            let collection = await makeCollection(entries: entries, context: context)
            guard loadGate.isCurrent(request, for: feed) else { return }
            collections[ref] = collection
            logMatch("\(provider) watchlist", collection)
            SectionFeedCache.shared.storeWatchlist(surface, provider, key: scoped(cacheKey), collection: collection)
            await refreshHeroArtwork()
            guard loadGate.isCurrent(request, for: feed) else { return }
            transition(.rowsRecovered([ref]))
            transition(.finished(.watchlist(provider), .loaded))
        } catch {
            // Preserve a stale row when revalidation fails. A transport error is
            // not evidence that the remote watchlist became empty.
            if cached == .missing, loadGate.isCurrent(request, for: feed) {
                collections[ref] = .empty
            }
            guard loadGate.isCurrent(request, for: feed) else { return }
            finishWatchlistFailure(provider, cached: cached)
        }
    }

    private func restoreWatchlist(_ provider: WatchlistProvider, cacheKey: String) -> CacheRestore {
        guard let cached = SectionFeedCache.shared.watchlistEntry(surface, provider, for: scoped(cacheKey)) else {
            return .missing
        }
        collections[.builtin(provider.section)] = cached.value
        return cached.isFresh ? .fresh : .stale
    }

    private func finishWatchlistFailure(_ provider: WatchlistProvider, cached: CacheRestore) {
        let ref = HomeSectionRef.builtin(provider.section)
        if cached != .missing, !items(for: ref).isEmpty {
            transition(.finished(.watchlist(provider), .loaded))
        } else {
            transition(.rowsFailed([ref]))
            transition(.finished(.watchlist(provider), .failed))
        }
    }
}

// MARK: - Context plumbing

extension SectionFeed {
    /// Set by the surface before each load. Held rather than passed to every
    /// call so the `.task` sites stay as short as they were when this logic
    /// lived on `HomeView`.
    func update(context: Context) {
        self.context = context
        transition(.contextChanged(identity: contextIdentity(context)))
    }

    private func contextIdentity(_ context: Context) -> String {
        "\(context.profileID?.uuidString ?? "*")|\(context.playlistPrefix ?? "*")|\(context.restriction.visibilityToken)"
    }

    /// A session-cache key scoped to the catalog it was matched against. The
    /// cached collections hold models from that scope, so a key the view
    /// happens to reuse after a scope change must not find them.
    func scoped(_ cacheKey: String) -> String {
        "\(loads.contextIdentity ?? "*")|\(cacheKey)"
    }

    /// How a resolved list met the catalog. "0 shown, 20 of 20 checked" means
    /// the list arrived but none of it matched — a catalog without TMDB ids, or
    /// the wrong playlist scope — which is otherwise indistinguishable on screen
    /// from a list that never loaded.
    func logMatch(_ label: String, _ collection: SectionCollectionSnapshot) {
        Logger.home.info(
            "\(surface.rawValue) \(label): \(collection.preview.count) shown, \(collection.nextOffset) of \(collection.entries.count) checked"
        )
    }

    /// The one way load state changes: applies `event`, journals the
    /// transition, and performs what the machine asks for.
    func transition(_ event: SectionFeedLoadMachine.Event) {
        let source: SectionFeedSource? = switch event {
        case let .began(source, _, _), let .finished(source, _): source
        case .contextChanged, .rowsFailed, .rowsRecovered, .rowBegan, .rowFinished, .skipped: nil
        }
        let before = source.map(loads.state(of:))
        guard source.map({ SectionFeedLoadMachine.isValid(event, in: loads.state(of: $0)) }) ?? true else {
            Logger.home.warning("\(surface.rawValue) \(String(describing: source)): ignored \(String(describing: event)) while \(String(describing: before))")
            return
        }
        let failedBefore = loads.failedRows
        let effects = loads.handle(event)
        for row in loads.failedRows.subtracting(failedBefore) {
            Logger.home.notice("\(surface.rawValue) row \(row.token): failed with nothing cached")
        }
        for row in failedBefore.subtracting(loads.failedRows) {
            Logger.home.info("\(surface.rawValue) row \(row.token): recovered")
        }
        if let source, let before {
            Logger.home.info("\(surface.rawValue) \(source): \(before) → \(loads.state(of: source))")
        }
        for effect in effects {
            perform(effect)
        }
        if case let .finished(source, .loaded) = event { recordTopShelfRows(for: source) }
    }

    private func perform(_ effect: SectionFeedLoadMachine.Effect) {
        switch effect {
        case .discardCatalogModels:
            // Catalog models belong to the previous playlist/visibility scope.
            // Drop them, and revoke every in-flight request so an A → B → A
            // switch cannot publish late.
            Logger.home.info("\(surface.rawValue): catalog scope changed; discarding matched rows")
            loadGate.invalidateAll()
            collections.removeAll()
            heroPresentationOverrides.removeAll()
            heroEnrichmentIDs.removeAll()
            heroArtworkRevision &+= 1
        case let .reload(source, key):
            guard loadPlan == nil else { return }
            // Usually the view's own tasks re-run for the new scope and begin
            // these loads themselves; give them a moment, then load whatever is
            // still idle so no source is left empty because its task didn't.
            Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(250))
                guard let self, loads.state(of: source) == .idle else { return }
                Logger.home.notice("\(surface.rawValue) \(source): reloading after scope change")
                switch source {
                case .trending: await loadTrending(cacheKey: key)
                case let .watchlist(provider): await loadWatchlist(provider, cacheKey: key)
                case .custom: await loadCustomSections(cacheKey: key, sections: requestedCustomSections)
                }
            }
        }
    }

    func makeCollection(
        entries: [HomeListEntry],
        context: Context
    ) async -> SectionCollectionSnapshot {
        await SectionCollectionResolver.snapshot(
            entries: entries,
            mediaType: surface.mediaType,
            context: context,
            previewLimit: Self.itemLimit
        )
    }

    func replaceCustomCollections(with custom: [UUID: SectionCollectionSnapshot]) {
        collections = collections.filter { key, _ in
            if case .custom = key { return false }
            return true
        }
        for (id, collection) in custom {
            collections[.custom(id)] = collection
        }
    }

    func publishCollection(_ collection: SectionCollectionSnapshot, for ref: HomeSectionRef) {
        if let previous = collections[ref],
           previous.preview.map(\.id) == collection.preview.map(\.id),
           previous.entries.map(\.reference) == collection.entries.map(\.reference),
           previous.continuation == collection.continuation { return }
        collections[ref] = collection
    }

    func removeCollection(for ref: HomeSectionRef) {
        collections[ref] = nil
    }

    private func requestsRow(_ ref: HomeSectionRef) -> Bool {
        loadPlan?.rows.contains(ref) ?? true
    }
}
