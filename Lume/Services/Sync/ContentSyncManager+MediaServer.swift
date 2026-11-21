//
//  ContentSyncManager+MediaServer.swift
//  Lume
//
//  The Jellyfin/Emby sync pipeline: authenticate, read the movie and TV-show
//  libraries view by view, and upsert the items into the catalog rows the
//  rest of the app already renders. Server metadata is trusted as-is —
//  unlike a file share there is nothing to classify by filename.
//
//  One pipeline serves both products because they are wire-compatible; the
//  only thing that varies is the `MediaServerFlavor` its rows are tagged with.
//

import Foundation
import OSLog
import SwiftData

extension ContentSyncManager {
    /// What every request of one sync shares: where the server is, who we
    /// are on it, and which product it is.
    struct JellyfinConnection {
        var server: URL
        var session: JellyfinSession
        var flavor: MediaServerFlavor
    }

    /// One library's import scope: everything the per-page upserts need beyond
    /// the items themselves. Bundled so the pipeline's helpers stay under the
    /// parameter-count lint.
    ///
    /// Not `private`: shared with `ContentSyncManager+MediaServerShows.swift`.
    struct JellyfinViewScope {
        var connection: JellyfinConnection
        var playlistId: UUID
        var view: JellyfinLibrary
        var categoryId: String
        /// Every library of this kind in the sync. A title listed by two of
        /// them stays under the one that already holds it, so libraries read
        /// in parallel don't move it back and forth.
        var libraryCategoryIds: Set<String> = []

        /// The category a row should carry: its own library's for a new row or
        /// one whose library is gone, otherwise the one it already has.
        func category(keeping current: String?) -> String {
            if let current, current != categoryId, libraryCategoryIds.contains(current) { return current }
            return categoryId
        }

        var server: URL {
            connection.server
        }

        var session: JellyfinSession {
            connection.session
        }

        var flavor: MediaServerFlavor {
            connection.flavor
        }

        /// The id prefix every row of this library carries. The flavour infix
        /// is what scopes the prune sweeps (see `MediaServerFlavor.idInfix`).
        var idPrefix: String {
            ContentSyncManager.mediaServerIdPrefix(playlistId, flavor: flavor)
        }
    }

    /// Syncs the movie and TV-show libraries of the kinds in `areas`; a
    /// switched-off kind is neither fetched nor swept (see
    /// `ContentSyncManager+AreaGating`).
    func performMediaServerSync(
        playlist: Playlist,
        playlistId: UUID,
        flavor: MediaServerFlavor,
        progress: SyncProgress?,
        areas: Set<AppArea>
    ) async throws {
        guard case let .mediaServer(sourceFlavor, base, credentials, _) = playlist.connection, sourceFlavor == flavor else {
            throw JellyfinError.invalidURL
        }
        let server = JellyfinClient.normalizedServerURL(base)

        await progress?.start(.authenticating)
        let session: JellyfinSession
        do {
            session = try await jellyfinClient.authenticate(server: server, username: credentials.username, password: credentials.password)
        } catch {
            let described = (error as? JellyfinError)?.logDescription ?? "login failed"
            let product = flavor.displayName
            Logger.database.error("\(product, privacy: .public) login aborted (\(described, privacy: .public)); catalog untouched")
            throw error
        }
        persistJellyfinSession(session, playlistId: playlistId)
        await progress?.complete(.authenticating)

        let connection = JellyfinConnection(server: server, session: session, flavor: flavor)
        let views = try await jellyfinClient.views(server: server, session: session)
        // A mixed-content library reports no `CollectionType` at all, and both
        // products let you make one. Walking it for movies *and* shows is what
        // keeps such a server from importing nothing at all; a library that is
        // neither (music, photos, books) still names its type and is skipped.
        // A non-media folder that happens to report no type costs one empty
        // query per kind, because the item query filters by type anyway.
        let movieViews = views.filter { $0.collectionType == "movies" || $0.collectionType == nil }
        let showViews = views.filter { $0.collectionType == "tvshows" || $0.collectionType == nil }
        if movieViews.isEmpty, showViews.isEmpty {
            Logger.database.info("\(flavor.displayName, privacy: .public) sync: no movie or TV-show libraries; catalog untouched")
        }

        // A library the server cuts short keeps its rows and skips its kind's
        // prune; the rest still import, and the sync reports it at the end.
        var incomplete: ProviderImportError?
        if areas.contains(.movies) {
            incomplete = try await syncJellyfinMoviePhase(views: movieViews, connection: connection, playlistId: playlistId, progress: progress)
        }
        if areas.contains(.series) {
            let showsIncomplete = try await syncJellyfinShowPhase(views: showViews, connection: connection, playlistId: playlistId, progress: progress)
            incomplete = incomplete ?? showsIncomplete
        }

        markPlaylistUpdated(playlistId)
        if let incomplete { throw incomplete }
    }

    /// A library without a fixed length is read this far (see
    /// `ProviderTotalTracker`): about ten pages of fifty, instead of paging
    /// until the source behind it runs dry, two seconds or more a page.
    static let openEndedLibraryItemLimit = 500

    /// Every movie library, up to four at a time, then the movie prune if all
    /// of them walked completely. Returns the first incomplete walk.
    private func syncJellyfinMoviePhase(
        views: [JellyfinLibrary], connection: JellyfinConnection, playlistId: UUID, progress: SyncProgress?
    ) async throws -> ProviderImportError? {
        try syncJellyfinCategories(views: views, type: .vod, playlistId: playlistId)
        await progress?.start(.movies)
        let scopes = jellyfinScopes(views, connection: connection, playlistId: playlistId, type: .vod)
        // One library reports its own pages; several report libraries done,
        // since their pages interleave.
        let pageProgress = views.count == 1 ? progress : nil
        let libraryProgress = views.count > 1 ? progress : nil
        let walk = try await walkLibrariesConcurrently(
            scopes, name: { $0.view.name }, isFatal: Self.endsJellyfinSync,
            finished: { await Self.reportLibraries($0, of: $1, progress: libraryProgress) },
            walk: { manager, scope in try await manager.syncJellyfinMovies(scope: scope, progress: pageProgress) }
        )
        if walk.incomplete == nil {
            let seen = walk.seen.reduce(into: Set<String>()) { $0.formUnion($1) }
            pruneJellyfinMovies(playlistId: playlistId, flavor: connection.flavor, seenIds: seen, fetched: !views.isEmpty)
        }
        await progress?.complete(.movies)
        return walk.incomplete
    }

    /// Every TV library, then the series/episode prune if all of them walked
    /// completely. Returns the first incomplete walk.
    private func syncJellyfinShowPhase(
        views: [JellyfinLibrary], connection: JellyfinConnection, playlistId: UUID, progress: SyncProgress?
    ) async throws -> ProviderImportError? {
        try syncJellyfinCategories(views: views, type: .series, playlistId: playlistId)
        await progress?.start(.series)
        let scopes = jellyfinScopes(views, connection: connection, playlistId: playlistId, type: .series)
        let pageProgress = views.count == 1 ? progress : nil
        let libraryProgress = views.count > 1 ? progress : nil
        let walk = try await walkLibrariesConcurrently(
            scopes, name: { $0.view.name }, isFatal: Self.endsJellyfinSync,
            finished: { await Self.reportLibraries($0, of: $1, progress: libraryProgress) },
            walk: { manager, scope in try await manager.syncJellyfinShows(scope: scope, progress: pageProgress) }
        )
        if walk.incomplete == nil {
            pruneJellyfinSeries(
                playlistId: playlistId, flavor: connection.flavor,
                seenSeries: walk.seen.reduce(into: Set<String>()) { $0.formUnion($1.series) },
                seenEpisodes: walk.seen.reduce(into: Set<String>()) { $0.formUnion($1.episodes) },
                fetched: !views.isEmpty
            )
        }
        await progress?.complete(.series)
        return walk.incomplete
    }

    private func jellyfinScopes(_ views: [JellyfinLibrary], connection: JellyfinConnection, playlistId: UUID, type: CategoryType) -> [JellyfinViewScope] {
        let categoryIds = views.map { CatalogID.category(playlistId, type: type.rawValue, key: $0.id) }
        return zip(views, categoryIds).map { view, categoryId in
            JellyfinViewScope(connection: connection, playlistId: playlistId, view: view,
                              categoryId: categoryId, libraryCategoryIds: Set(categoryIds))
        }
    }

    /// A rejected login ends the sync; anything else one library hits only
    /// skips that library.
    private static func endsJellyfinSync(_ error: Error) -> Bool {
        if case .unauthorized = error as? JellyfinError { return true }
        return false
    }

    private static func reportLibraries(_ done: Int, of total: Int, progress: SyncProgress?) async {
        await progress?.update(detail: "\(done) of \(total) libraries", fraction: total == 0 ? 1 : Double(done) / Double(total))
    }

    // MARK: - Paging

    /// Pages a recursive item query to exhaustion, handing each page to `body`.
    /// Returns the number of items seen. Shared by the movie, series and
    /// episode walks so the three differ only in what they do per page.
    /// Not `private`: shared with `ContentSyncManager+MediaServerShows.swift`.
    func pageThroughJellyfinItems(
        types: [String],
        scope: JellyfinViewScope,
        progress: SyncProgress?,
        unit: String,
        body: ([JellyfinItem]) throws -> Void
    ) async throws -> Int {
        try await walkProviderPages(openEndedLimit: Self.openEndedLibraryItemLimit) { startIndex in
            let page = try await jellyfinClient.items(
                server: scope.server, session: scope.session, parentId: scope.view.id, types: types,
                startIndex: startIndex
            )
            return ProviderImportPage(items: page.items, total: page.totalRecordCount)
        } consume: { items in
            try body(items)
        } report: { fetched, total in
            await progress?.update(detail: "\(fetched) of \(total) \(unit) in \(scope.view.name)", fraction: total == 0 ? 1 : Double(fetched) / Double(total))
        }
    }

    // MARK: - Session

    /// Stores the fresh session on the playlist so playback and artwork can
    /// authenticate without logging in again. A rotated or revoked token is
    /// simply replaced on the next sync, which always logs in first.
    private func persistJellyfinSession(_ session: JellyfinSession, playlistId: UUID) {
        updatePlaylist(playlistId) { playlist in
            playlist.jellyfinAccessToken = session.accessToken
            playlist.jellyfinUserId = session.userId
        }
    }

    // MARK: - Categories

    /// One category per Jellyfin library, updated in place so a rename keeps
    /// `isHidden` / `customOrder`. Mirrors `syncCategories`' empty-gate: an
    /// empty view list is the transient-failure signature, never a deletion.
    private func syncJellyfinCategories(views: [JellyfinLibrary], type: CategoryType, playlistId: UUID) throws {
        try syncProviderCategories(views.map { ProviderCategory(id: $0.id, name: $0.name) }, type: type, playlistId: playlistId)
    }

    // MARK: - Movies

    private func syncJellyfinMovies(scope: JellyfinViewScope, progress: SyncProgress?) async throws -> Set<String> {
        var seen = Set<String>()
        let fetched = try await pageThroughJellyfinItems(types: ["Movie"], scope: scope, progress: progress, unit: "movie(s)") { items in
            try seen.formUnion(upsertJellyfinMovies(items, scope: scope))
        }
        Logger.database.info("\(scope.flavor.displayName, privacy: .public) movies synced for library \(scope.view.name, privacy: .public): \(fetched, privacy: .public) item(s)")
        return seen
    }

    /// Upserts one page of movies, returning the ids it saw for the prune
    /// sweep. A set (not an inout) so the paging loop can feed pages through a
    /// closure, which cannot capture an inout parameter.
    private func upsertJellyfinMovies(_ items: [JellyfinItem], scope: JellyfinViewScope) throws -> Set<String> {
        let context = ModelContext(modelContainer)
        context.autosaveEnabled = false
        let seen = try CatalogUpsert.batch(items, context: context,
                                           identity: { scope.idPrefix + $0.id },
                                           create: { item, id in Movie(id: id, streamId: M3UIdentity.numericId(for: item.id), name: item.name ?? "") },
                                           apply: { applyJellyfinMovieFields($0, to: $1, scope: scope) })
        if context.hasChanges {
            try context.save()
        }
        return Set(seen)
    }

    /// Copies the server-owned fields onto the row, leaving user state
    /// (favorites, progress, downloads) intact. Every write is inequality
    /// guarded: SwiftData dirties a row on assignment, not on change. Split in
    /// two halves (identity + metadata) for the complexity lint.
    private func applyJellyfinMovieFields(_ item: JellyfinItem, to movie: Movie, scope: JellyfinViewScope) {
        applyJellyfinMovieIdentity(item, to: movie, scope: scope)
        applyJellyfinMovieMetadata(item, to: movie)
    }

    private func applyJellyfinMovieIdentity(_ item: JellyfinItem, to movie: Movie, scope: JellyfinViewScope) {
        let name = item.name ?? ""
        if movie.name != name {
            movie.name = name
        }
        let category = scope.category(keeping: movie.categoryId)
        if movie.categoryId != category {
            movie.categoryId = category
        }
        if let url = JellyfinClient.streamURL(server: scope.server, itemId: item.id)?.absoluteString,
           movie.directURL != url
        {
            movie.directURL = url
        }
        if let tag = item.primaryImageTag,
           let url = JellyfinClient.imageURL(server: scope.server, itemId: item.id, tag: tag)?.absoluteString,
           movie.streamIcon != url
        {
            movie.streamIcon = url
        }
        let rating = item.communityRating ?? 0
        if movie.rating != rating {
            movie.rating = rating
        }
        if movie.rating5Based != rating / 2 {
            movie.rating5Based = rating / 2
        }
    }

    private func applyJellyfinMovieMetadata(_ item: JellyfinItem, to movie: Movie) {
        if movie.plot != item.overview {
            movie.plot = item.overview
        }
        let genre = item.genres?.joined(separator: ", ")
        if movie.genre != genre {
            movie.genre = genre
        }
        let release = item.premiereDate.map { String($0.prefix(10)) }
        if movie.releaseDate != release {
            movie.releaseDate = release
        }
        if movie.durationSecs != item.durationSecs {
            movie.durationSecs = item.durationSecs
        }
        if let container = item.container?.split(separator: ",").first.map({ String($0).lowercased() }),
           movie.containerExtension != container
        {
            movie.containerExtension = container
        }
        let suppliedTMDB = item.providerIds?["Tmdb"]
        movie.applyCatalogueTMDB(suppliedTMDB, previous: movie.tmdb)
        if movie.tmdb != suppliedTMDB { movie.tmdb = suppliedTMDB }
        if let imdb = item.providerIds?["Imdb"], movie.imdbId != imdb {
            movie.imdbId = imdb
        }
        let added = item.dateCreated.map { String($0.prefix(10)) }
        if movie.added != added {
            movie.added = added
        }
    }

    /// Removes movies the server no longer lists. Gated on `fetched`: an empty
    /// library list is the transient-failure signature, and sweeping then
    /// would drop the whole catalog. Past that, the paged, coverage-gated
    /// sweep in `ContentSyncManager+Prune.swift`, scoped to the flavour's own
    /// id prefix so rows of any other source are never read.
    private func pruneJellyfinMovies(playlistId: UUID, flavor: MediaServerFlavor, seenIds: Set<String>, fetched: Bool) {
        guard fetched else { return }
        pruneMovies(playlistId: playlistId, idPrefix: Self.mediaServerIdPrefix(playlistId, flavor: flavor), seenIds: seenIds)
    }

    /// The prefix every row of `flavor` for this playlist carries — the same
    /// string `JellyfinViewScope.idPrefix` builds.
    nonisolated static func mediaServerIdPrefix(_ playlistId: UUID, flavor: MediaServerFlavor) -> String {
        CatalogID.prefix(playlistId, infix: flavor.idInfix)
    }
}
