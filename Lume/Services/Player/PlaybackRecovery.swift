//
//  PlaybackRecovery.swift
//  Lume
//
//  What a launch recovers from `WatchProgressBuffer`, told to the linked
//  trackers. A crashed or killed session never sent its last pause or stop,
//  so Trakt and Simkl still hold whatever came before. A position that
//  crossed the watched line goes as watched history; anything else as the
//  pause it would have sent, through each tracker's durable queue — it waits
//  for the account to connect, and a newer pause there wins.
//

import Foundation
import SwiftData

@MainActor
enum PlaybackRecovery {
    static func report(
        _ recovered: [WatchProgressWriter.Recovered],
        to trackers: [any TrackerHistorySynchronizing],
        in context: ModelContext
    ) {
        for item in recovered {
            let finished = item.change?.isWatched == true
            let percent = pausedPercent(progress: item.progress, duration: item.duration)
            switch item.ref {
            case let .movie(id):
                guard let movie = PlayerContentLookup.movie(id, in: context) else { continue }
                send(finished: finished, percent: percent, to: trackers,
                     watched: { $0.syncWatched(movie: movie, watched: true) },
                     paused: { $0.recordPausedProgress(movie: movie, progress: $1, pausedAt: item.recordedAt) })
            case let .episode(id):
                guard let episode = PlayerContentLookup.episode(id, in: context) else { continue }
                send(finished: finished, percent: percent, to: trackers,
                     watched: { $0.syncWatched(episode: episode, watched: true) },
                     paused: { $0.recordPausedProgress(episode: episode, progress: $1, pausedAt: item.recordedAt) })
            case .live:
                continue
            }
        }
    }

    /// Watched once finished; otherwise the pause, when there's one to keep.
    private static func send(
        finished: Bool, percent: Double?, to trackers: [any TrackerHistorySynchronizing],
        watched: (any TrackerHistorySynchronizing) -> Void,
        paused: (any TrackerHistorySynchronizing, Double) -> Void
    ) {
        for tracker in trackers {
            if finished {
                watched(tracker)
            } else if let percent {
                paused(tracker, percent)
            }
        }
    }

    /// The position as a percentage, or nil when there's nothing to resume:
    /// no known duration, or under 1% (Trakt rejects those).
    static func pausedPercent(progress: TimeInterval, duration: TimeInterval) -> Double? {
        guard duration > 0, progress.isFinite else { return nil }
        let percent = min(progress / duration * 100, 100)
        return percent >= 1 ? percent : nil
    }
}
