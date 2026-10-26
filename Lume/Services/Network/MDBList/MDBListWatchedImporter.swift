//
//  MDBListWatchedImporter.swift
//  Lume
//
//  Reads MDBList's `/sync/watched` history for the shared
//  `TrackerWatchedImporter`, which marks the catalog and parks what it can't
//  mark yet in `MDBListPendingWatchedStore`.
//

import Foundation
import SwiftData

nonisolated enum MDBListPendingWatchedStore: TrackerPendingWatchedStoring {
    static let fileName = "MDBListPendingWatched.json"
    static let trackerName = "MDBList"
    static let cache = TrackerPendingWatchedCache()
    nonisolated(unsafe) static var directory: URL? = TrackerPendingStorage.directory

    static var currentScope: TrackerScope {
        .mdblist
    }
}

nonisolated enum MDBListWatchedImporter {
    private typealias Importer = TrackerWatchedImporter<MDBListPendingWatchedStore>

    static func apply(_ history: MDBListWatchedHistory, in context: ModelContext, pendingScope: TrackerScope = .mdblist) -> TrackerWatchedImportSummary {
        Importer.apply(Self.history(history), in: context, pendingScope: pendingScope)
    }

    /// Applies parked MDBList progress to a series whose episodes just arrived.
    @discardableResult
    static func applyPending(to series: Series) -> Int {
        Importer.applyPending(to: series)
    }

    /// Unwatching keeps a row with a null timestamp, so only a row that
    /// carries one counts as watched.
    static func history(_ history: MDBListWatchedHistory) -> TrackerWatchedHistory {
        var shows: [Int: [TrackerEpisodeKey: Date?]] = [:]
        var order: [Int] = []
        for row in history.episodes {
            guard let tmdb = row.episode.show.ids.tmdb, let date = MDBListDates.parse(row.lastWatchedAt) else { continue }
            if shows[tmdb] == nil { order.append(tmdb) }
            shows[tmdb, default: [:]][TrackerEpisodeKey(season: row.episode.season, episode: row.episode.number)] = date
        }
        return TrackerWatchedHistory(
            movies: history.movies.compactMap { row in
                guard let tmdb = row.movie.ids.tmdb, let date = MDBListDates.parse(row.lastWatchedAt) else { return nil }
                return TrackerWatchedHistory.WatchedMovie(tmdbID: tmdb, watchedAt: date)
            },
            shows: order.map { TrackerWatchedHistory.WatchedShow(tmdbID: $0, episodes: shows[$0] ?? [:]) }
        )
    }
}

/// One import transaction's worth of history: a bounded run of titles, so a
/// long history never holds one context open over the whole catalog.
nonisolated enum MDBListHistoryPage {
    case movies([TrackerWatchedHistory.WatchedMovie])
    case shows([TrackerWatchedHistory.WatchedShow])

    static func plan(_ history: TrackerWatchedHistory) -> [Self] {
        let movies = TrackerImportPages.groups(history.movies, maximumKeys: 100, key: { $0.tmdbID }).map(Self.movies)
        let shows = TrackerImportPages.groups(history.shows, maximumKeys: 10, key: { $0.tmdbID }).map(Self.shows)
        let pages = movies + shows
        return pages.isEmpty ? [.movies([])] : pages
    }

    func apply(in context: ModelContext, scope: TrackerScope) -> TrackerWatchedImportSummary {
        let history = switch self {
        case let .movies(movies): TrackerWatchedHistory(movies: movies)
        case let .shows(shows): TrackerWatchedHistory(shows: shows)
        }
        return TrackerWatchedImporter<MDBListPendingWatchedStore>.apply(history, in: context, pendingScope: scope)
    }
}
