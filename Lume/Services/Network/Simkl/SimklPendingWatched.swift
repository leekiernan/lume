//
//  SimklPendingWatched.swift
//  Lume
//
//  Where a Simkl import parks the watched episodes of shows whose episodes
//  aren't in the catalog yet — see `TrackerPendingWatchedStoring`.
//

import Foundation

nonisolated enum SimklPendingWatchedStore: TrackerPendingWatchedStoring {
    static let fileName = "SimklPendingWatched.json"
    static let trackerName = "Simkl"
    static let cache = TrackerPendingWatchedCache()
    nonisolated(unsafe) static var directory: URL? = TrackerPendingStorage.directory

    static var currentScope: TrackerScope {
        .simkl
    }
}
