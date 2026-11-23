//
//  SimklWatchedImporter.swift
//  Lume
//
//  Reads Simkl's `/sync/all-items/` library as a watched history for the
//  shared `TrackerWatchedImporter`, which marks the catalog and parks what it
//  can't mark yet in `SimklPendingWatchedStore`. The reverse direction of the
//  durable watched sync in `SimklService`.
//

import Foundation
import SwiftData

nonisolated enum SimklWatchedImporter {
    private typealias Importer = TrackerWatchedImporter<SimklPendingWatchedStore>

    /// Marks the local movies and episodes that Simkl reports as watched,
    /// writing through the given catalog context. Returns what changed.
    static func apply(items: SimklAllItems, in context: ModelContext, pendingScope: TrackerScope = .simkl) -> TrackerWatchedImportSummary {
        apply(movies: items.movies, shows: items.shows, in: context, pendingScope: pendingScope)
    }

    /// Marks the local movies and episodes that Simkl reports as watched,
    /// writing through the given catalog context. Returns what changed.
    static func apply(
        movies: [SimklWatchedMovie],
        shows: [SimklWatchedShow],
        in context: ModelContext,
        pendingScope: TrackerScope = .simkl
    ) -> TrackerWatchedImportSummary {
        Importer.apply(history(movies: movies, shows: shows), in: context, pendingScope: pendingScope)
    }

    /// Applies parked Simkl progress to a series whose episodes just arrived.
    @discardableResult
    static func applyPending(to series: Series) -> Int {
        Importer.applyPending(to: series)
    }

    /// Only completed movies count, and a show Simkl reports without any
    /// season progress has nothing to apply, now or later.
    static func history(movies: [SimklWatchedMovie], shows: [SimklWatchedShow]) -> TrackerWatchedHistory {
        TrackerWatchedHistory(
            movies: movies.compactMap { item in
                guard item.isWatched, let tmdb = item.movie.ids.tmdb else { return nil }
                return TrackerWatchedHistory.WatchedMovie(tmdbID: tmdb, watchedAt: LenientISO8601.date(from: item.lastWatchedAt))
            },
            shows: shows.compactMap { show in
                guard let tmdb = show.show.ids.tmdb, !show.seasons.isEmpty else { return nil }
                var episodes: [TrackerEpisodeKey: Date?] = [:]
                for season in show.seasons {
                    for episode in season.episodes {
                        episodes[TrackerEpisodeKey(season: season.number, episode: episode.number)] = LenientISO8601.date(from: episode.lastWatchedAt)
                    }
                }
                return TrackerWatchedHistory.WatchedShow(tmdbID: tmdb, episodes: episodes)
            }
        )
    }
}
