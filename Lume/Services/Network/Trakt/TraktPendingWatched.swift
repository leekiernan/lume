//
//  TraktPendingWatched.swift
//  Lume
//
//  Trakt's parked watched and paused episodes: the shared tracker store
//  (`TrackerPendingWatchedStoring`), plus the pauses only Trakt's playback
//  import parks. Same file name and format as before the stores were shared.
//

import Foundation

nonisolated enum TraktPendingWatchedStore: TrackerPendingWatchedStoring {
    static let fileName = "TrackerPendingWatched.json"
    static let trackerName = "Trakt"
    static let cache = TrackerPendingWatchedCache()
    nonisolated(unsafe) static var directory: URL? = TrackerPendingStorage.directory

    static var currentScope: TrackerScope {
        .trakt
    }

    static func applyParkedPauses(_ paused: [String: TrackerPendingPause], to series: Series, now: Date) -> [String: TrackerPendingPause] {
        TraktPlaybackImporter.applyParked(paused, to: series, now: now)
    }
}
