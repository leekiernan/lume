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
//  For a movie, removal is an unwatch (`MediaWatchState`): local progress
//  goes, and a linked Trakt or Simkl account drops it from its history too.
//  Clearing only the local stamp didn't last — the tracker still held the
//  play, and the next launch's import put the title back.
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
        MediaWatchState.setWatched(false, movie: movie, in: context, trackers: trackers)
    }

    /// Takes `series`' title out of both watch rails.
    static func remove(_ series: Series, in context: ModelContext) {
        var copies = [series]
        if let tmdbId = series.tmdbId {
            let descriptor = FetchDescriptor<Series>(predicate: #Predicate { $0.tmdbId == tmdbId && $0.lastWatchedDate != nil })
            copies += ((try? context.fetch(descriptor)) ?? []).filter { $0.id != series.id }
        }
        for copy in copies {
            copy.lastWatchedDate = nil
        }
        ContentClearLedger.shared.record(copies.map(\.id))
        try? context.save()
    }
}
