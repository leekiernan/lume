//
//  WatchRailRemoval.swift
//  Lume
//
//  "Remove from Recently Watched" / "Continue Watching" for a movie or series.
//  The rails show one card per title (`deduplicatedByTitle`), so the card can
//  stand for several watched copies — a 4K and an HD entry, or the same film
//  on another playlist. Clearing only the card's copy let the next one take
//  its place, and the viewer had to remove the title once per copy. This
//  clears every watched copy sharing the TMDB id, the identity the rails
//  collapse by.
//
//  Removal is an unwatch (`MediaWatchState`): local progress goes, and a
//  linked Trakt or Simkl account drops the play from its history and its
//  paused progress, which trackers keep apart from history. Clearing only the
//  local stamp didn't last — the tracker still held the play, and the next
//  launch's import put the title back.
//
//  A series card stands for the episode it continues with, so removing it
//  unwatches that episode. With earlier episodes watched the series stays,
//  now continuing at the start of that episode.
//

import Foundation
import SwiftData

enum WatchRailRemoval {
    /// Unwatches `movie`'s title, every copy, here and on linked trackers.
    static func remove(_ movie: Movie, in context: ModelContext, trackers: [any TrackerHistorySynchronizing]? = nil) {
        if let tmdbId = movie.tmdbId {
            let descriptor = FetchDescriptor<Movie>(predicate: #Predicate {
                $0.tmdbId == tmdbId && ($0.isWatched || $0.lastWatchedDate != nil || $0.watchProgress > 0)
            })
            for copy in (try? context.fetch(descriptor)) ?? [] where copy.id != movie.id {
                copy.setWatched(false)
            }
        }
        // Trackers key the title by TMDB id, which the copies share, so the
        // representative's unwatch carries all of them.
        let trackers = trackers ?? defaultTrackers
        MediaWatchState.setWatched(false, movie: movie, in: context, trackers: trackers)
        for tracker in trackers {
            tracker.clearPausedProgress(movie: movie)
        }
    }

    /// Unwatches the episode `series`' card continues with, on every copy of
    /// the title. A card on an episode not yet started — or a series whose
    /// episodes aren't loaded — takes the series off the rails instead.
    static func remove(
        _ series: Series, continuing continuation: SeriesContinuation?,
        in context: ModelContext, trackers: [any TrackerHistorySynchronizing]? = nil
    ) {
        let copies = copies(of: series, in: context)
        let started = continuation.map { shown in
            copies.flatMap(\.episodes).filter {
                $0.seasonNum == shown.season && $0.episodeNum == shown.episode
                    && ($0.watchProgress > 0 || $0.lastWatchedDate != nil)
            }
        } ?? []
        guard let episode = started.first(where: { $0.series?.id == series.id }) ?? started.first else {
            forget(copies, in: context)
            return
        }
        for copy in started where copy.id != episode.id {
            copy.setWatched(false)
        }
        let trackers = trackers ?? defaultTrackers
        MediaWatchState.setWatched(false, episode: episode, in: context, trackers: trackers)
        for tracker in trackers {
            tracker.clearPausedProgress(episode: episode)
        }
    }

    private static var defaultTrackers: [any TrackerHistorySynchronizing] {
        [TraktService.shared, SimklService.shared]
    }

    /// `series` and the other watched copies of its title.
    private static func copies(of series: Series, in context: ModelContext) -> [Series] {
        guard let tmdbId = series.tmdbId else { return [series] }
        let descriptor = FetchDescriptor<Series>(predicate: #Predicate { $0.tmdbId == tmdbId && $0.lastWatchedDate != nil })
        return [series] + ((try? context.fetch(descriptor)) ?? []).filter { $0.id != series.id }
    }

    private static func forget(_ copies: [Series], in context: ModelContext) {
        for copy in copies {
            copy.lastWatchedDate = nil
        }
        ContentClearLedger.shared.record(copies.map(\.id))
        try? context.save()
    }
}
