//
//  TrackerHistorySynchronizing.swift
//  Lume
//
//  Shared app-facing contract for connected media trackers. Durable watched
//  history is user intent; playback scrobbles are transient and intentionally
//  have a separate capability.
//

import SwiftData

@MainActor
protocol TrackerHistorySynchronizing: AnyObject {
    func syncWatched(movie: Movie, watched: Bool)
    func syncWatched(episode: Episode, watched: Bool)
    /// Removes the title's paused progress, which history removal leaves.
    func clearPausedProgress(movie: Movie)
    func clearPausedProgress(episode: Episode)
    func retryPendingMutations()
}

extension TraktService: TrackerHistorySynchronizing {}
extension SimklService: TrackerHistorySynchronizing {}
