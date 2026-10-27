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
        guard let episode = episodes.first else { return }
        for version in episodes {
            version.setWatched(watched)
        }
        try? context.save()
        for tracker in trackers ?? MediaTrackers.all {
            tracker.syncWatched(episode: episode, watched: watched)
            if !watched { tracker.clearPausedProgress(episode: episode) }
        }
        for version in episodes {
            deleteCompletedDownload(watched: watched, id: version.id)
        }
    }

    private static func deleteCompletedDownload(watched: Bool, id: String) {
        #if !os(tvOS)
            if watched { DownloadManager.shared.checkAutoDelete(id: id) }
        #endif
    }
}
