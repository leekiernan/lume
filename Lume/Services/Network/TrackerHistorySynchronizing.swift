//
//  TrackerHistorySynchronizing.swift
//  Lume
//
//  Shared app-facing contract for connected media trackers. Durable watched
//  history is user intent; playback scrobbles are transient and intentionally
//  have a separate capability.
//

import Foundation
import SwiftData

@MainActor
protocol TrackerHistorySynchronizing: AnyObject {
    func syncWatched(movie: Movie, watched: Bool)
    func syncWatched(episode: Episode, watched: Bool)
    /// Removes the title's paused progress, which history removal leaves.
    func clearPausedProgress(movie: Movie)
    func clearPausedProgress(episode: Episode)
    /// Queues a position a crashed or killed session never sent, as a pause
    /// at `progress` percent reached at `pausedAt`.
    func recordPausedProgress(movie: Movie, progress: Double, pausedAt: Date)
    func recordPausedProgress(episode: Episode, progress: Double, pausedAt: Date)
    func retryPendingMutations()
}

/// Playback start, pause and stop, which every tracker takes the same way.
/// Transient, unlike history: see `TraktPlaybackScrobbler`.
@MainActor
protocol TrackerScrobbling: AnyObject {
    func scrobble(_ target: TraktScrobbleTarget, action: TraktScrobbleAction, progress: Double)
}

extension TraktService: TrackerHistorySynchronizing, TrackerScrobbling {}
extension SimklService: TrackerHistorySynchronizing, TrackerScrobbling {}
extension MDBListService: TrackerHistorySynchronizing, TrackerScrobbling {}

/// A tracker watchlist the heart adds to and removes from — see
/// `MediaFavorites` and `WatchlistProvider.service`.
@MainActor
protocol TrackerWatchlistSyncing: AnyObject {
    var isConnected: Bool { get }
    /// The account membership belongs to, once known.
    var watchlistAccount: String? { get }
    func isWatchlisted(_ target: TrackerMutation.Target) -> Bool
    func refreshWatchlistIfNeeded() async
    func syncWatchlist(movie: Movie, watchlisted: Bool)
    func syncWatchlist(series: Series, watchlisted: Bool)
}

extension TraktService: TrackerWatchlistSyncing {
    var watchlistAccount: String? {
        mutations.account
    }

    func isWatchlisted(_ target: TrackerMutation.Target) -> Bool {
        mutations.isWatchlisted(target)
    }
}

extension SimklService: TrackerWatchlistSyncing {
    var watchlistAccount: String? {
        mutations.account
    }

    func isWatchlisted(_ target: TrackerMutation.Target) -> Bool {
        mutations.isWatchlisted(target)
    }
}

extension MDBListService: TrackerWatchlistSyncing {
    var watchlistAccount: String? {
        mutations.account
    }

    func isWatchlisted(_ target: TrackerMutation.Target) -> Bool {
        mutations.isWatchlisted(target)
    }
}

/// Every tracker integration, listed once: watched sync, scrobbles and rail
/// removal fan out to these, so a new service is one entry here. Each
/// service no-ops while it isn't connected.
@MainActor
enum MediaTrackers {
    static var all: [any TrackerHistorySynchronizing & TrackerScrobbling] {
        [TraktService.shared, SimklService.shared, MDBListService.shared]
    }
}
