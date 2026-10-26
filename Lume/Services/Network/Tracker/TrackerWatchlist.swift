//
//  TrackerWatchlist.swift
//  Lume
//
//  A tracker's watchlist as every surface reads it — Home's watchlist rows and
//  the heart — and the last good read of it kept on disk. The read itself is
//  `TrackerMutationQueue.watchlistEntries()`: each tracker supplies only how to
//  fetch, so all of them share one coalescing rule, one offline fallback and
//  one launch-time membership.
//
//  The saved copy is derived state, not user data: it lives in Caches, belongs
//  to one account, and is deleted on disconnect.
//

import Foundation
import OSLog

/// One watchlist title, in the tracker's order.
nonisolated struct TrackerWatchlistEntry: Codable, Equatable {
    let target: TrackerMutation.Target
    /// For diagnostics; rows display the catalog's own title. Empty when the
    /// tracker's list carries none.
    var title = ""
}

/// Why a watchlist read produced nothing to show.
nonisolated enum TrackerWatchlistError: Error, Equatable {
    /// Signed out, or the account changed while the read ran.
    case notConnected
}

/// The last successful watchlist read per tracker, for its account only.
nonisolated enum TrackerWatchlistStore {
    private struct Snapshot: Codable {
        let account: String
        let entries: [TrackerWatchlistEntry]
    }

    /// Caches. The unit tests run inside the installed app, so the test bundle
    /// points this at a temporary directory (`PendingStoreIsolation`).
    nonisolated(unsafe) static var directory: URL? = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first

    private static func fileURL(_ tracker: String) -> URL? {
        directory?.appendingPathComponent("\(tracker)WatchlistSnapshot.json")
    }

    /// The saved entries, or nil when there are none for `account` — another
    /// account's copy is never handed back.
    static func load(_ tracker: String, account: String) -> [TrackerWatchlistEntry]? {
        guard let url = fileURL(tracker), let data = try? Data(contentsOf: url),
              let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data),
              snapshot.account == account
        else { return nil }
        return snapshot.entries
    }

    static func save(_ tracker: String, account: String, entries: [TrackerWatchlistEntry]) {
        guard let url = fileURL(tracker) else { return }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(Snapshot(account: account, entries: entries)).write(to: url, options: .atomic)
        } catch {
            Logger.network.error("Couldn't save the \(tracker, privacy: .public) watchlist: \(error.localizedDescription, privacy: .public)")
        }
    }

    static func clear(_ tracker: String) {
        guard let url = fileURL(tracker) else { return }
        try? FileManager.default.removeItem(at: url)
    }
}

/// A tracker service that owns a `TrackerMutationQueue` gets the heart's
/// watchlist behaviour from it; each service only sets the queue's
/// `fetchWatchlist`.
@MainActor
protocol TrackerQueueOwning: TrackerWatchlistSyncing {
    associatedtype Backend: TrackerAccountBackend
    var mutations: TrackerMutationQueue<Backend> { get }
}

extension TrackerQueueOwning {
    var watchlistAccount: String? {
        mutations.account
    }

    func isWatchlisted(_ target: TrackerMutation.Target) -> Bool {
        mutations.isWatchlisted(target)
    }

    func refreshWatchlistIfNeeded() async {
        await mutations.refreshWatchlistIfNeeded()
    }

    func watchlistEntries() async throws -> [TrackerWatchlistEntry] {
        try await mutations.watchlistEntries()
    }

    /// Captures the TMDB id before anything asynchronous, so the SwiftData
    /// model never crosses an actor boundary.
    func syncWatchlist(movie: Movie, watchlisted: Bool) {
        guard let tmdbID = movie.tmdbId else { return }
        mutations.enqueue(.watchlist, .movie(tmdbID: tmdbID), isPresent: watchlisted)
    }

    func syncWatchlist(series: Series, watchlisted: Bool) {
        guard let tmdbID = series.tmdbId else { return }
        mutations.enqueue(.watchlist, .show(tmdbID: tmdbID), isPresent: watchlisted)
    }
}
