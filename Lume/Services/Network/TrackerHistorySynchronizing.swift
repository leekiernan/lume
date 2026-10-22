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

extension TraktService: TrackerHistorySynchronizing {}
extension SimklService: TrackerHistorySynchronizing {}
