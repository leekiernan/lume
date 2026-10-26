//
//  TrackerWatchedImporter.swift
//  Lume
//
//  Applies a tracker's watched history onto the local catalog: marks matching
//  movies and episodes as watched. Shared by the trackers whose import carries
//  watched state only (Simkl, MDBList); each decodes its own payload into a
//  `TrackerWatchedHistory` first. Run on connect and on demand from the
//  tracker's settings screen.
//
//  Matching is by TMDB id (the only external id the library carries), so titles
//  without a resolved `tmdbId` are skipped. Already-watched items are left
//  untouched so the import is idempotent and the returned counts reflect only
//  what actually changed.
//
//  Series need one extra step. Xtream and Stalker episodes are fetched lazily by
//  the series detail screen, so a show the user has never opened has a `Series`
//  row but no `Episode` rows — nothing for the import to mark. Rather than pull
//  every watched show's episodes here (one ~250 KB provider request each), the
//  import parks that state in the tracker's `TrackerPendingWatchedStoring` and
//  `Series.insertEpisodes` applies it when the detail screen fetches the
//  episodes anyway. The series' `lastWatchedDate` is stamped immediately either
//  way, so Home's Recently Watched row is right the moment the import finishes.
//

import Foundation
import SwiftData

/// The outcome of an import, surfaced in the settings UI.
nonisolated struct TrackerWatchedImportSummary: Equatable, TrackerPagedSummary {
    var moviesMarked = 0
    var episodesMarked = 0
    /// Shows whose watched episodes were parked because the catalog has no
    /// episodes for them yet. They are applied on first open of the series.
    var showsQueued = 0
    var failed = false

    static let failure = TrackerWatchedImportSummary(failed: true)

    var markedNothing: Bool {
        !failed && moviesMarked == 0 && episodesMarked == 0 && showsQueued == 0
    }

    mutating func add(_ page: Self) {
        moviesMarked += page.moviesMarked
        episodesMarked += page.episodesMarked
        showsQueued += page.showsQueued
        failed = failed || page.failed
    }
}

/// One season and episode number.
nonisolated struct TrackerEpisodeKey: Hashable {
    let season: Int
    let episode: Int
}

/// A tracker's watched history, decoded and reduced to what the catalog
/// matches on.
nonisolated struct TrackerWatchedHistory {
    struct WatchedMovie {
        let tmdbID: Int
        let watchedAt: Date?
    }

    struct WatchedShow {
        let tmdbID: Int
        /// Each watched episode, with when it was last watched if known.
        let episodes: [TrackerEpisodeKey: Date?]
    }

    var movies: [WatchedMovie] = []
    var shows: [WatchedShow] = []
}

nonisolated enum TrackerWatchedImporter<Store: TrackerPendingWatchedStoring> {
    /// Marks the local movies and episodes the history reports as watched,
    /// writing through the given catalog context. Returns what changed.
    static func apply(_ history: TrackerWatchedHistory, in context: ModelContext, pendingScope: TrackerScope) -> TrackerWatchedImportSummary {
        let moviesMarked = importMovies(history.movies, in: context, profileID: pendingScope.profileID)
        let shows = importShows(history.shows, in: context, pendingScope: pendingScope)
        let summary = TrackerWatchedImportSummary(moviesMarked: moviesMarked, episodesMarked: shows.marked, showsQueued: shows.queued)
        guard context.hasChanges else { return summary }
        do {
            try context.save()
            return summary
        } catch {
            var failed = summary
            failed.failed = true
            return failed
        }
    }

    // MARK: - Movies

    private static func importMovies(_ watched: [TrackerWatchedHistory.WatchedMovie], in context: ModelContext, profileID: UUID?) -> Int {
        var watchedIDs = Set<Int>()
        var dates: [Int: Date] = [:]
        for item in watched {
            watchedIDs.insert(item.tmdbID)
            if let date = item.watchedAt {
                dates[item.tmdbID] = date
            }
        }
        guard !watchedIDs.isEmpty else { return 0 }

        let candidates = TrackerCatalogLookup.movies(tmdbIDs: watchedIDs, in: context)

        var count = 0
        for movie in candidates where !movie.isWatched {
            guard let tmdb = movie.tmdbId, watchedIDs.contains(tmdb) else { continue }
            guard WatchHistoryClears.shared.allows(dates[tmdb], for: movie.id, profileID: profileID) else { continue }
            // A rewatch or local unwatched decision made after the remote play
            // must survive the import, as on Trakt.
            if let local = movie.lastWatchedDate, (dates[tmdb] ?? .distantPast) <= local { continue }
            movie.isWatched = true
            movie.watchProgress = Double(movie.durationSecs ?? 0)
            if let date = dates[tmdb] {
                movie.lastWatchedDate = date
            }
            count += 1
        }
        return count
    }

    // MARK: - Shows

    private static func importShows(
        _ watched: [TrackerWatchedHistory.WatchedShow],
        in context: ModelContext,
        pendingScope: TrackerScope
    ) -> (marked: Int, queued: Int) {
        var showsByTMDB: [Int: TrackerWatchedHistory.WatchedShow] = [:]
        for show in watched {
            showsByTMDB[show.tmdbID] = show
        }
        guard !showsByTMDB.isEmpty else { return (0, 0) }

        let candidates = TrackerCatalogLookup.series(tmdbIDs: Set(showsByTMDB.keys), in: context)

        var pending = Store.load(scope: pendingScope)
        var pendingChanged = false
        var marked = 0
        var queued = 0

        for series in candidates {
            guard let tmdb = series.tmdbId, let show = showsByTMDB[tmdb] else { continue }
            let progress = Progress(episodes: show.episodes)

            // Home's Recently Watched row queries this column, and playback
            // stamps it too (`WatchProgressWriter`). Set it whether or not the
            // episodes exist yet, so an imported show surfaces right away.
            if series.episodes.isEmpty, let newest = progress.newest, newest > (series.lastWatchedDate ?? .distantPast) {
                series.lastWatchedDate = newest
            }

            if series.episodes.isEmpty {
                // Nothing to mark yet. Park it for `Series.insertEpisodes`, which
                // runs when the detail screen fetches the episodes anyway.
                let updated = progress.parked
                if pending[tmdb] != updated {
                    pending[tmdb] = updated
                    pendingChanged = true
                }
                queued += 1
            } else {
                marked += markEpisodes(of: series, using: progress, profileID: pendingScope.profileID)
                series.refreshWatchRecency(onlyAdvancing: true)
                // Episodes are present, so anything parked by an earlier import
                // has just been superseded.
                if pending[tmdb] != nil {
                    pending[tmdb] = nil
                    pendingChanged = true
                }
            }
        }

        if pendingChanged {
            Store.save(pending)
        }
        return (marked, queued)
    }

    /// One show's watched episodes, in both the form the marking loop wants and
    /// the form that gets parked on disk.
    struct Progress {
        var dates: [TrackerEpisodeKey: Date?]
        var newest: Date?

        init(episodes: [TrackerEpisodeKey: Date?]) {
            dates = episodes
            newest = episodes.values.compactMap(\.self).max()
        }

        init(parked: TrackerPendingShow) {
            var episodes: [TrackerEpisodeKey: Date?] = [:]
            for (key, seconds) in parked.episodes {
                let parts = key.split(separator: "x")
                guard parts.count == 2, let season = Int(parts[0]), let episode = Int(parts[1]) else { continue }
                episodes[TrackerEpisodeKey(season: season, episode: episode)] = seconds.map { Date(timeIntervalSince1970: TimeInterval($0)) }
            }
            self.init(episodes: episodes)
        }

        var parked: TrackerPendingShow {
            var episodes: [String: Int?] = [:]
            for (key, date) in dates {
                episodes[TrackerPendingShow.key(season: key.season, episode: key.episode)] =
                    date.map { Int($0.timeIntervalSince1970) }
            }
            return TrackerPendingShow(episodes: episodes)
        }
    }

    /// Applies parked progress to episodes that have just been fetched from the
    /// provider, and drops the entry once it has been used. Called from
    /// `Series.insertEpisodes`, the single place episodes ever materialize.
    @discardableResult
    static func applyPending(to series: Series) -> Int {
        guard let tmdb = series.tmdbId, !series.episodes.isEmpty else { return 0 }
        guard let parked = Store.load()[tmdb] else { return 0 }

        let progress = Progress(parked: parked)
        let marked = markEpisodes(of: series, using: progress, profileID: ActiveProfileStore.current)
        series.refreshWatchRecency(onlyAdvancing: true)
        Store.clear(tmdbID: tmdb)
        return marked
    }

    /// Marks the episodes of `series` the tracker reports watched, returning
    /// how many changed.
    private static func markEpisodes(of series: Series, using progress: Progress, profileID: UUID?) -> Int {
        var count = 0
        for episode in series.episodes {
            let key = TrackerEpisodeKey(season: episode.seasonNum, episode: episode.episodeNum)
            guard let date = progress.dates[key] else { continue }
            if TrackerEpisodeHistory.applyCompletion(date, to: episode, profileID: profileID) { count += 1 }
        }
        return count
    }
}
