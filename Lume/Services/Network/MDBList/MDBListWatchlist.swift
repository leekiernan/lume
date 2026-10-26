//
//  MDBListWatchlist.swift
//  Lume
//
//  The MDBList watchlist behind Home's MDBList row and the heart: reading it,
//  newest first, and adding or removing a title.
//

import Foundation

/// A watchlist title reduced to what Home matches on: movie or show, and its
/// TMDB id.
nonisolated struct MDBListWatchlistEntry: Equatable {
    enum Kind {
        case movie
        case show
    }

    let kind: Kind
    let tmdbID: Int
    let addedAt: Date?

    var target: TrackerMutation.Target {
        switch kind {
        case .movie: .movie(tmdbID: tmdbID)
        case .show: .show(tmdbID: tmdbID)
        }
    }
}

/// Decoded `/watchlist/items` page.
nonisolated struct MDBListWatchlistPage: Decodable, MDBListPaged {
    let movies: [MDBListWatchlistItem]
    let shows: [MDBListWatchlistItem]
    let pagination: MDBListPagination?

    var itemCount: Int {
        movies.count + shows.count
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        movies = try container.decodeIfPresent([MDBListWatchlistItem].self, forKey: .movies) ?? []
        shows = try container.decodeIfPresent([MDBListWatchlistItem].self, forKey: .shows) ?? []
        pagination = try container.decodeIfPresent(MDBListPagination.self, forKey: .pagination)
    }

    enum CodingKeys: String, CodingKey {
        case movies, shows, pagination
    }

    var entries: [MDBListWatchlistEntry] {
        movies.compactMap { $0.entry(kind: .movie) } + shows.compactMap { $0.entry(kind: .show) }
    }
}

/// One watchlist row. Its `id` is the title's TMDB id; a newer `ids` block is
/// read first when present.
nonisolated struct MDBListWatchlistItem: Decodable {
    let id: Int?
    let ids: MDBListIDs?
    let watchlistAt: String?

    enum CodingKeys: String, CodingKey {
        case id, ids
        case watchlistAt = "watchlist_at"
    }

    fileprivate func entry(kind: MDBListWatchlistEntry.Kind) -> MDBListWatchlistEntry? {
        guard let tmdbID = ids?.tmdb ?? id else { return nil }
        return MDBListWatchlistEntry(kind: kind, tmdbID: tmdbID, addedAt: MDBListDates.parse(watchlistAt))
    }
}

/// Body for `/watchlist/items/{add,remove}`: bare id bags, not the sync
/// endpoints' `{"ids": …}` wrapping.
nonisolated struct MDBListWatchlistMutation: Encodable {
    var movies: [MDBListIDs] = []
    var shows: [MDBListIDs] = []

    init?(target: TrackerMutation.Target) {
        switch target {
        case let .movie(tmdbID): movies = [MDBListIDs(tmdb: tmdbID)]
        case let .show(tmdbID): shows = [MDBListIDs(tmdb: tmdbID)]
        case .episode: return nil
        }
    }
}

nonisolated extension MDBListSyncClient {
    /// The user's watchlist, every page merged, most recently added first.
    func watchlist(accessToken: String) async throws -> [MDBListWatchlistEntry] {
        var entries: [MDBListWatchlistEntry] = []
        try await forEachPage(
            "/watchlist/items",
            query: [URLQueryItem(name: "sort", value: "added"), URLQueryItem(name: "order", value: "desc")],
            accessToken: accessToken
        ) { (page: MDBListWatchlistPage) in
            entries += page.entries
        }
        // Movies and shows come back as two lists; merge them by date added.
        return entries.enumerated()
            .sorted { lhs, rhs in
                let lhsDate = lhs.element.addedAt ?? .distantPast
                let rhsDate = rhs.element.addedAt ?? .distantPast
                return lhsDate == rhsDate ? lhs.offset < rhs.offset : lhsDate > rhsDate
            }
            .map(\.element)
    }

    /// Adds or removes a movie or show. False for an episode, which a
    /// watchlist doesn't hold. Adding a title already there, or removing one
    /// that isn't, is a success.
    func setWatchlist(_ target: TrackerMutation.Target, watchlisted: Bool, accessToken: String) async throws -> Bool {
        guard let items = MDBListWatchlistMutation(target: target) else { return false }
        try await post("/watchlist/items/\(watchlisted ? "add" : "remove")", body: items, accessToken: accessToken)
        return true
    }
}
