//
//  WatchRailRemoval.swift
//  Lume
//
//  "Remove from Continue Watching" / "Remove from Recently Watched" for a
//  movie or series. The rails show one card per title
//  (`deduplicatedByTitle`), so the card can stand for several copies — a 4K
//  and an HD entry, or the same film on another playlist. Clearing only the
//  card's copy let the next one take its place, so each removal applies to
//  every copy sharing the TMDB id, the identity the rails collapse by.
//
//  The two rails mean different things:
//  - Continue Watching forgets that an unfinished title was started: local
//    progress, and the paused place Trakt and Simkl keep. Watched history
//    stays — clearing an unfinished title isn't unwatching it.
//  - Recently Watched unwatches a finished movie (`MediaWatchState`), here
//    and on linked trackers.
//  Clearing only the local stamp didn't last: the tracker still held the
//  play, and the next launch's import put the title back.
//
//  A series card stands for the episode it continues with, so Continue
//  Watching clears that episode. With earlier episodes watched the series
//  stays, now continuing at the start of that episode.
//

import Foundation
import SwiftData

enum WatchRailRemoval {
    // MARK: - Continue Watching

    /// Forgets that `movie` was started, on every copy, here and on trackers.
    static func removeFromContinueWatching(
        _ movie: Movie, in context: ModelContext, trackers: [any TrackerHistorySynchronizing]? = nil
    ) {
        for copy in copies(of: movie, in: context) where !copy.isWatched {
            copy.clearProgress()
        }
        try? context.save()
        // Trackers key the title by TMDB id, which the copies share.
        for tracker in trackers ?? defaultTrackers {
            tracker.clearPausedProgress(movie: movie)
        }
    }

    /// Forgets that the episode `series`' card continues with was started, on
    /// every copy of the title. A card on an episode not yet started — or a
    /// series whose episodes aren't loaded — takes the series off the rails.
    static func removeFromContinueWatching(
        _ series: Series, continuing continuation: SeriesContinuation?,
        in context: ModelContext, trackers: [any TrackerHistorySynchronizing]? = nil
    ) {
        let copies = copies(of: series, in: context)
        let started = continuation.map { shown in
            copies.flatMap(\.episodes).filter {
                $0.seasonNum == shown.season && $0.episodeNum == shown.episode
                    && !$0.isWatched && ($0.watchProgress > 0 || $0.lastWatchedDate != nil)
            }
        } ?? []
        guard let episode = started.first(where: { $0.series?.id == series.id }) ?? started.first else {
            forget(copies, in: context)
            return
        }
        for copy in started {
            copy.clearProgress()
        }
        try? context.save()
        for tracker in trackers ?? defaultTrackers {
            tracker.clearPausedProgress(episode: episode)
        }
    }

    // MARK: - Recently Watched

    /// Unwatches `movie`'s title, every copy, here and on linked trackers.
    static func removeFromRecentlyWatched(
        _ movie: Movie, in context: ModelContext, trackers: [any TrackerHistorySynchronizing]? = nil
    ) {
        for copy in copies(of: movie, in: context) where copy.id != movie.id {
            copy.setWatched(false)
        }
        // The representative's unwatch carries every copy to the trackers.
        MediaWatchState.setWatched(false, movie: movie, in: context, trackers: trackers)
    }

    /// Takes a finished series off the rails.
    static func removeFromRecentlyWatched(_ series: Series, in context: ModelContext) {
        forget(copies(of: series, in: context), in: context)
    }

    // MARK: - Copies

    private static var defaultTrackers: [any TrackerHistorySynchronizing] {
        [TraktService.shared, SimklService.shared]
    }

    /// `movie` and the other started copies of its title.
    private static func copies(of movie: Movie, in context: ModelContext) -> [Movie] {
        guard let tmdbId = movie.tmdbId else { return [movie] }
        let descriptor = FetchDescriptor<Movie>(predicate: #Predicate {
            $0.tmdbId == tmdbId && ($0.isWatched || $0.lastWatchedDate != nil || $0.watchProgress > 0)
        })
        return [movie] + ((try? context.fetch(descriptor)) ?? []).filter { $0.id != movie.id }
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
