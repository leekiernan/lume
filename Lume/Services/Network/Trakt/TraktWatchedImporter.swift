//
//  TraktWatchedImporter.swift
//  Lume
//
//  Applies the watched history fetched from Trakt onto the local catalog. The
//  reverse direction of the scrobbling in `TraktService`, run at startup and on
//  demand from Settings. Trakt's payload is reduced to a
//  `TrackerWatchedHistory` and applied by the importer every tracker shares
//  (`TrackerWatchedImporter`), so the rules — matching, rewatches, parking a
//  show's episodes until they're fetched — are the same for all of them.
//

import Foundation
import SwiftData

/// The outcome of an import, surfaced in the settings UI.
nonisolated struct TraktImportSummary: Equatable, TrackerPagedSummary {
    var moviesMarked = 0
    var episodesMarked = 0
    /// Shows whose watched episodes were parked because the catalog has no
    /// episodes for them yet. They are applied on first open of the series.
    var showsQueued = 0
    /// Titles paused part-way on Trakt (`TraktPlaybackImporter`).
    var inProgress = 0
    var failed = false

    static let failure = TraktImportSummary(failed: true)

    var markedNothing: Bool {
        !failed && moviesMarked == 0 && episodesMarked == 0 && showsQueued == 0 && inProgress == 0
    }
}

nonisolated enum TraktWatchedImporter {
    private typealias Importer = TrackerWatchedImporter<TraktPendingWatchedStore>

    /// Marks the local movies and episodes that Trakt reports as watched, writing
    /// through the given catalog context. Returns what changed.
    static func apply(
        movies: [TraktWatchedMovie],
        shows: [TraktWatchedShow],
        in context: ModelContext,
        pendingScope: TrackerScope = .trakt
    ) -> TraktImportSummary {
        let summary = Importer.apply(history(movies: movies, shows: shows), in: context, pendingScope: pendingScope)
        return TraktImportSummary(
            moviesMarked: summary.moviesMarked,
            episodesMarked: summary.episodesMarked,
            showsQueued: summary.showsQueued,
            failed: summary.failed
        )
    }

    /// Applies parked watched state, then parked pauses, to episodes that have
    /// just been fetched (`TrackerWatchedImporter.applyPending`).
    @discardableResult
    static func applyPending(to series: Series, now: Date = .now) -> Int {
        Importer.applyPending(to: series, now: now)
    }

    static func history(movies: [TraktWatchedMovie], shows: [TraktWatchedShow]) -> TrackerWatchedHistory {
        TrackerWatchedHistory(
            movies: movies.compactMap { item in
                item.movie.ids.tmdb.map { .init(tmdbID: $0, watchedAt: LenientISO8601.date(from: item.lastWatchedAt)) }
            },
            shows: shows.compactMap { show in
                // A show Trakt reports without any season progress has nothing
                // to apply, now or later.
                guard let tmdb = show.show.ids.tmdb, !show.seasons.isEmpty else { return nil }
                var episodes: [TrackerEpisodeKey: Date?] = [:]
                for season in show.seasons {
                    for episode in season.episodes {
                        episodes[TrackerEpisodeKey(season: season.number, episode: episode.number)] = LenientISO8601.date(from: episode.lastWatchedAt)
                    }
                }
                return .init(tmdbID: tmdb, episodes: episodes)
            }
        )
    }
}
