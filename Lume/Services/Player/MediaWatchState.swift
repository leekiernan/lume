import Foundation
import SwiftData

/// Watched/reset intent, shared by card menus, details and early player exits.
/// A reset is total: progress, history and the trackers' paused places. A
/// marked title is marked in every version (`TitleVersions`), with one change
/// per tracker for the title.
/// Model mutations maintain recency/resume state; tracker queues keep their
/// existing account/profile ownership. This is a discrete action, not playback
/// clock persistence (which remains owned by `WatchProgressWriter`).
enum MediaWatchState {
    enum EpisodeRangeAction: Equatable {
        case markEarlierWatched, resetLater

        var watched: Bool {
            self == .markEarlierWatched
        }
    }

    private struct EpisodePosition: Hashable, Comparable {
        let season: Int
        let episode: Int

        init(_ episode: Episode) {
            season = episode.seasonNum
            self.episode = episode.episodeNum
        }

        static func < (lhs: Self, rhs: Self) -> Bool {
            (lhs.season, lhs.episode) < (rhs.season, rhs.episode)
        }
    }

    /// Bulk intent uses the same effects as a single title. Fetch versions
    /// once, save once, and derive each affected show's recency once.
    static func apply(
        _ action: EpisodeRangeAction, relativeTo episode: Episode, in context: ModelContext,
        trackers: [any TrackerHistorySynchronizing]? = nil
    ) {
        guard let series = episode.series else { return }
        let anchor = EpisodePosition(episode)
        let candidates = TitleVersions.episodes(of: series, in: context).filter {
            action.watched ? EpisodePosition($0) < anchor : EpisodePosition($0) > anchor
        }
        let byPosition = Dictionary(grouping: candidates, by: EpisodePosition.init)
        let groups = byPosition.keys.sorted().compactMap { position -> [Episode]? in
            guard let versions = byPosition[position], versions.contains(where: {
                action.watched ? !$0.isWatched : $0.isWatched || $0.watchProgress > 0 || $0.lastWatchedDate != nil
            }) else { return nil }
            return versions
        }
        setWatched(action.watched, groups: groups, in: context, trackers: trackers)
    }

    /// An early exit resets unfinished content using the same ledger and
    /// tracker delivery as a manual reset. A brief replay must not erase an
    /// existing completed watch. Returns whether this boundary was handled.
    static func discardEarlyProgress(
        ref: PlayableMedia.ContentRef, position: TimeInterval, duration: TimeInterval,
        in context: ModelContext, trackers: [any TrackerHistorySynchronizing]? = nil
    ) -> Bool {
        guard PlaybackResumePolicy.discardsProgress(position: position, duration: duration) else { return false }
        switch ref {
        case let .movie(id):
            // Only the version played: a quick look at one version must not
            // wipe the place reached in another.
            guard let movie = PlayerContentLookup.movie(id, in: context) else { return false }
            if !movie.isWatched { setWatched(false, movies: [movie], in: context, trackers: trackers) }
        case let .episode(id):
            guard let episode = PlayerContentLookup.episode(id, in: context) else { return false }
            if !episode.isWatched { setWatched(false, episodes: [episode], in: context, trackers: trackers) }
        case .live:
            return false
        }
        RecentResumePoints.record(0, for: ref)
        return true
    }

    static func setWatched(
        _ watched: Bool, movie: Movie, in context: ModelContext,
        trackers: [any TrackerHistorySynchronizing]? = nil
    ) {
        setWatched(watched, movies: TitleVersions.movies(of: movie, in: context), in: context, trackers: trackers)
    }

    static func setWatched(
        _ watched: Bool, episode: Episode, in context: ModelContext,
        trackers: [any TrackerHistorySynchronizing]? = nil
    ) {
        setWatched(watched, episodes: TitleVersions.episodes(of: episode, in: context), in: context, trackers: trackers)
    }

    /// Marks `movies` — versions of one title, the first the one acted on —
    /// and tells each tracker once, for the title.
    private static func setWatched(
        _ watched: Bool, movies: [Movie], in context: ModelContext, trackers: [any TrackerHistorySynchronizing]?
    ) {
        guard let movie = movies.first else { return }
        for version in movies {
            version.setWatched(watched)
        }
        try? context.save()
        for tracker in trackers ?? MediaTrackers.all {
            tracker.syncWatched(movie: movie, watched: watched)
            // History removal leaves the paused place behind.
            if !watched { tracker.clearPausedProgress(movie: movie) }
        }
        for version in movies {
            deleteCompletedDownload(watched: watched, id: version.id)
        }
    }

    private static func setWatched(
        _ watched: Bool, episodes: [Episode], in context: ModelContext, trackers: [any TrackerHistorySynchronizing]?
    ) {
        setWatched(watched, groups: [episodes], in: context, trackers: trackers)
    }

    private static func setWatched(
        _ watched: Bool, groups: [[Episode]], in context: ModelContext, trackers: [any TrackerHistorySynchronizing]?
    ) {
        let episodes = groups.flatMap(\.self)
        guard !episodes.isEmpty else { return }
        var shows: [String: Series] = [:]
        for episode in episodes {
            episode.applyWatched(watched)
            if let series = episode.series { shows[series.id] = series }
        }
        for series in shows.values {
            series.refreshWatchRecency()
            if series.lastWatchedDate == nil { ContentClearLedger.shared.record(series.id) }
        }
        try? context.save()
        for group in groups {
            guard let episode = group.first else { continue }
            for tracker in trackers ?? MediaTrackers.all {
                tracker.syncWatched(episode: episode, watched: watched)
                if !watched { tracker.clearPausedProgress(episode: episode) }
            }
        }
        for episode in episodes {
            deleteCompletedDownload(watched: watched, id: episode.id)
        }
    }

    private static func deleteCompletedDownload(watched: Bool, id: String) {
        #if !os(tvOS)
            if watched { DownloadManager.shared.checkAutoDelete(id: id) }
        #endif
    }
}
