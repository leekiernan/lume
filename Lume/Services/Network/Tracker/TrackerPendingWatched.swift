//
//  TrackerPendingWatched.swift
//  Lume
//
//  Holds the watched episodes a tracker import could not apply yet, for the
//  trackers whose import parks watched state only (Simkl, MDBList; Trakt's
//  own store also parks pauses).
//
//  Xtream and Stalker only expose episodes through a per-series
//  `get_series_info` call that the series detail screen makes on first open, so
//  a show the user has never opened has a `Series` row and no `Episode` rows.
//  Fetching them all at import time would mean one request per watched show —
//  roughly 250 KB each, so tens of megabytes and minutes of waiting for a
//  hundred shows — to populate episodes nobody is looking at yet.
//
//  Instead the import parks that state, keyed by the show's TMDB id, and
//  `Series.insertEpisodes` applies it when the detail screen materializes the
//  episodes anyway. Zero extra provider requests; the ticks are simply in place
//  the first time the user opens the series.
//
//  Derived state, not user data: it is rebuilt by the next import, excluded from
//  backup, and an entry is pruned once it has been applied. Each tracker keeps
//  its own file so the integrations never overwrite each other's parked
//  progress.
//

import Foundation
import OSLog

/// The watched episodes of one show, as `season × episode → last watched`.
/// Dates are epoch seconds so the on-disk form stays compact — a hundred shows
/// of a long-running series is ~120 KB rather than ~1 MB of ISO-8601 strings.
nonisolated struct TrackerPendingShow: Codable, Equatable {
    /// Keys are `"<season>x<episode>"`; values are epoch seconds, or nil when
    /// the tracker reported no timestamp for that episode.
    var episodes: [String: Int?]

    static func key(season: Int, episode: Int) -> String {
        "\(season)x\(episode)"
    }
}

/// The parked watched state, keyed by the show's TMDB id (as a string, so the
/// whole thing is a plain JSON object).
nonisolated struct TrackerPendingWatched: Codable, Equatable {
    var shows: [String: TrackerPendingShow] = [:]
    /// The profile whose import parked this. The file is device-wide but the
    /// watched state is per profile/account: another scope neither applies it
    /// nor merges into it (`TrackerPendingWatchedStoring`). Legacy files without
    /// an account stamp are rebuilt by the next import, not replayed.
    var profileID: UUID?

    /// Stable provider account partition; absent legacy files are not replayed.
    var accountID: String?

    var scope: TrackerScope {
        get { TrackerScope(profileID: profileID, accountID: accountID) }
        set { profileID = newValue.profileID; accountID = newValue.accountID }
    }

    static let empty = TrackerPendingWatched()

    var isEmpty: Bool {
        shows.isEmpty
    }

    subscript(tmdbID: Int) -> TrackerPendingShow? {
        get { shows[String(tmdbID)] }
        set { shows[String(tmdbID)] = newValue }
    }
}

/// The in-memory copy of one store's file, so the per-series lookup in
/// `insertEpisodes` costs nothing after the first hit.
final nonisolated class TrackerPendingWatchedCache: @unchecked Sendable {
    private let lock = NSLock()
    private var value: TrackerPendingWatched?

    func withLock<Result>(_ body: (inout TrackerPendingWatched?) -> Result) -> Result {
        lock.withLock { body(&value) }
    }
}

/// One tracker's parked state on disk. A conformer names its file, its scope
/// and its cache; reading and writing are shared.
nonisolated protocol TrackerPendingWatchedStoring {
    static var fileName: String { get }
    /// The tracker's name, for the log.
    static var trackerName: String { get }
    /// The active profile and this tracker's connected account.
    static var currentScope: TrackerScope { get }
    /// The directory the parked state is kept in. The unit tests run inside
    /// the installed app, so the test bundle points this at a temporary
    /// directory before any test runs (`PendingStoreIsolation`).
    static var directory: URL? { get set }
    static var cache: TrackerPendingWatchedCache { get }
}

nonisolated extension TrackerPendingWatchedStoring {
    /// Where the parked state lives. Excluded from backup — the next import
    /// rebuilds it from the tracker.
    static var fileURL: URL? {
        directory?.appendingPathComponent(fileName)
    }

    /// The parked state for the active profile and account, on episode open.
    static func load() -> TrackerPendingWatched {
        load(scope: currentScope)
    }

    /// A captured import scope. Unstamped legacy files and unknown accounts
    /// cannot authorize replay.
    static func load(scope: TrackerScope) -> TrackerPendingWatched {
        let stored = loadStored()
        if stored.scope.matches(scope) { return stored }
        return TrackerPendingWatched(profileID: scope.profileID, accountID: scope.accountID)
    }

    private static func loadStored() -> TrackerPendingWatched {
        cache.withLock { cached in
            if let cached {
                return cached
            }
            guard let url = fileURL, let data = try? Data(contentsOf: url),
                  let decoded = try? JSONDecoder().decode(TrackerPendingWatched.self, from: data)
            else {
                cached = .empty
                return .empty
            }
            cached = decoded
            return decoded
        }
    }

    /// Keep the captured scope; never relabel old history as a new account/profile.
    static func save(_ state: TrackerPendingWatched) {
        guard state.scope.matches(currentScope) else { return }
        cache.withLock { cached in
            cached = state
            guard let url = fileURL else { return }
            // Nothing left to apply — drop the file rather than leaving an empty
            // object behind.
            guard !state.isEmpty else {
                try? FileManager.default.removeItem(at: url)
                return
            }
            do {
                // Resolving the storage directory does not create it. Also
                // recreate it if tvOS purged the cache between launches.
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try JSONEncoder().encode(state).write(to: url, options: .atomic)
                var resourceValues = URLResourceValues()
                resourceValues.isExcludedFromBackup = true
                var mutable = url
                try? mutable.setResourceValues(resourceValues)
            } catch {
                let reason = error.localizedDescription
                Logger.database.error("\(trackerName, privacy: .public) pending watched save failed: \(reason, privacy: .public)")
            }
        }
    }

    /// Removes one show's parked state, after its episodes have been marked.
    static func clear(tmdbID: Int) {
        var state = load()
        guard state[tmdbID] != nil else { return }
        state[tmdbID] = nil
        save(state)
    }

    /// Drops everything — used when disconnecting the account, so a stale
    /// import can't keep marking episodes for a signed-out user.
    static func clearAll() {
        cache.withLock { cached in
            cached = nil
            if let url = fileURL { try? FileManager.default.removeItem(at: url) }
        }
    }

    /// Test seam: forgets the in-memory copy so the next `load()` re-reads disk.
    static func resetCacheForTesting() {
        cache.withLock { $0 = nil }
    }
}
