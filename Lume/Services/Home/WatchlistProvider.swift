//
//  WatchlistProvider.swift
//  Lume
//
//  The tracker services that can back a watchlist row on a section surface,
//  and the heart's membership. Each names its row, the connected account and
//  how its watchlist reads as catalog-matchable entries; `SectionFeed` runs
//  one load, cache and failure path for all of them, and `MediaFavorites` one
//  heart, so a new service is a case here rather than a second copy of either.
//

import SwiftUI

nonisolated enum WatchlistProvider: CaseIterable, Hashable {
    case trakt
    case simkl

    /// The service behind a watchlist row; nil for every other row.
    init?(section: HomeSection) {
        guard let provider = Self.allCases.first(where: { $0.section == section }) else { return nil }
        self = provider
    }

    var section: HomeSection {
        switch self {
        case .trakt: .traktWatchlist
        case .simkl: .simklWatchlist
        }
    }

    /// The row's header on every surface. The layout settings use the shorter
    /// `HomeSection.title`.
    var rowTitle: LocalizedStringKey {
        switch self {
        case .trakt: "From Your Trakt Watchlist"
        case .simkl: "From Your Simkl Watchlist"
        }
    }

    /// `rowTitle` resolved, for the "show all" grid's title.
    var rowTitleString: String {
        switch self {
        case .trakt: String(localized: "From Your Trakt Watchlist")
        case .simkl: String(localized: "From Your Simkl Watchlist")
        }
    }

    /// The service's name, as the favourite menus show it.
    var name: String {
        switch self {
        case .trakt: "Trakt"
        case .simkl: "Simkl"
        }
    }

    /// The template image marking the service beside the heart.
    var markImage: String {
        switch self {
        case .trakt: "TraktMark"
        case .simkl: "SimklMark"
        }
    }

    /// The service that holds this watchlist and receives the heart's changes.
    @MainActor
    var service: any TrackerWatchlistSyncing {
        switch self {
        case .trakt: TraktService.shared
        case .simkl: SimklService.shared
        }
    }

    /// The connected account, or nil when signed out. Part of every load key,
    /// so connecting, disconnecting or switching account reloads the row.
    @MainActor
    var account: String? {
        switch self {
        case .trakt: TraktService.shared.username
        case .simkl: SimklService.shared.username
        }
    }

    @MainActor
    var isConnected: Bool {
        account != nil
    }

    /// The watchlist in the service's own order. Trakt throws on a transport
    /// failure, so a stale row survives it; Simkl already falls back to its
    /// on-disk copy (see `SimklService.fetchWatchlist`) and never throws.
    @MainActor
    func entries() async throws -> [HomeListEntry] {
        switch self {
        case .trakt:
            try await TraktService.shared.watchlistItems().compactMap(Self.entry)
        case .simkl:
            await SimklService.shared.fetchWatchlist().map(Self.entry)
        }
    }

    private static func entry(_ item: TraktWatchlistItem) -> HomeListEntry? {
        switch item.type {
        case "movie":
            guard let media = item.movie, let tmdbId = media.ids.tmdb else { return nil }
            return HomeListEntry(tmdbId: tmdbId, mediaType: .movie, title: media.title ?? "")
        case "show":
            guard let media = item.show, let tmdbId = media.ids.tmdb else { return nil }
            return HomeListEntry(tmdbId: tmdbId, mediaType: .series, title: media.title ?? "")
        default:
            return nil
        }
    }

    /// Simkl's watchlist carries no titles — only what the catalog matches on.
    private static func entry(_ item: SimklWatchlistEntry) -> HomeListEntry {
        switch item.kind {
        case .movie: HomeListEntry(tmdbId: item.tmdbID, mediaType: .movie, title: "")
        case .show: HomeListEntry(tmdbId: item.tmdbID, mediaType: .series, title: "")
        }
    }
}
