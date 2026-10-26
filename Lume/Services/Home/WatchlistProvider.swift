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
    case mdblist

    /// The service behind a watchlist row; nil for every other row.
    init?(section: HomeSection) {
        guard let provider = Self.allCases.first(where: { $0.section == section }) else { return nil }
        self = provider
    }

    var section: HomeSection {
        switch self {
        case .trakt: .traktWatchlist
        case .simkl: .simklWatchlist
        case .mdblist: .mdblistWatchlist
        }
    }

    /// The row's header on every surface. The layout settings use the shorter
    /// `HomeSection.title`.
    var rowTitle: LocalizedStringKey {
        switch self {
        case .trakt: "From Your Trakt Watchlist"
        case .simkl: "From Your Simkl Watchlist"
        case .mdblist: "From Your MDBList Watchlist"
        }
    }

    /// `rowTitle` resolved, for the "show all" grid's title.
    var rowTitleString: String {
        switch self {
        case .trakt: String(localized: "From Your Trakt Watchlist")
        case .simkl: String(localized: "From Your Simkl Watchlist")
        case .mdblist: String(localized: "From Your MDBList Watchlist")
        }
    }

    /// The service's name, as the favourite menus show it.
    var name: String {
        switch self {
        case .trakt: "Trakt"
        case .simkl: "Simkl"
        case .mdblist: "MDBList"
        }
    }

    /// The template image marking the service beside the heart. MDBList has
    /// no published mark, so a symbol stands in.
    var mark: Image {
        switch self {
        case .trakt: Image("TraktMark")
        case .simkl: Image("SimklMark")
        case .mdblist: Image(systemName: "list.star")
        }
    }

    /// The service that holds this watchlist and receives the heart's changes.
    @MainActor
    var service: any TrackerWatchlistSyncing {
        switch self {
        case .trakt: TraktService.shared
        case .simkl: SimklService.shared
        case .mdblist: MDBListService.shared
        }
    }

    /// The connected account, or nil when signed out. Part of every load key,
    /// so connecting, disconnecting or switching account reloads the row.
    @MainActor
    var account: String? {
        switch self {
        case .trakt: TraktService.shared.username
        case .simkl: SimklService.shared.username
        case .mdblist: MDBListService.shared.username
        }
    }

    @MainActor
    var isConnected: Bool {
        account != nil
    }

    /// The watchlist in the service's own order. Every tracker reads it the
    /// same way (`TrackerMutationQueue.watchlistEntries()`): an unreachable
    /// tracker answers with its last good read, and throws only when it has
    /// none, so a stale row survives a failure.
    @MainActor
    func entries() async throws -> [HomeListEntry] {
        try await service.watchlistEntries().compactMap { entry in
            switch entry.target {
            case let .movie(tmdbID): HomeListEntry(tmdbId: tmdbID, mediaType: .movie, title: entry.title)
            case let .show(tmdbID): HomeListEntry(tmdbId: tmdbID, mediaType: .series, title: entry.title)
            case .episode: nil
            }
        }
    }
}
