//
//  SimklService.swift
//  Lume
//
//  The app-wide coordinator for the Simkl integration. Owns the OAuth token
//  lifecycle (device-flow connect, refresh, disconnect), exposes connection
//  state for the Settings UI to observe, queues watched changes in a durable
//  outbox, and fetches the watchlist for Home. Mirrors `TraktService` against
//  the Simkl AUTH V2 API.
//
//  A shared singleton because watched-state changes originate from many places
//  (player completion, detail-screen toggles, model methods) that don't all
//  have access to the SwiftUI environment. It's still `@Observable`, so views
//  observe `SimklService.shared` directly. Watched mutations use the same
//  durable account-scoped outbox contract as Trakt; playback scrobbles remain
//  deliberately unsupported by Simkl for now.
//

import Foundation
import OSLog
import SwiftData
import SwiftUI

@MainActor
@Observable
final class SimklService {
    static let shared = SimklService()

    /// Sign-in and tokens — shared with Trakt, see `TrackerAccountSession`.
    let session: TrackerAccountSession<SimklAccountBackend>

    /// The connected Simkl username, or nil when signed out or not yet known.
    var username: String? {
        session.username
    }

    /// The in-flight device code while the user is approving authorization.
    var pendingCode: SimklDeviceCode? {
        session.pendingCode
    }

    /// A human-readable failure from the last connect attempt, surfaced in the
    /// Settings UI. Cleared when a new attempt begins.
    var connectionError: String? {
        session.connectionError
    }

    /// Whether a device-code authorization is in progress.
    var isConnecting: Bool {
        session.isConnecting
    }

    /// Whether a watched-history import is currently running.
    private(set) var isImporting = false

    /// The result of the most recent import, surfaced in the Settings UI.
    /// Cleared when a new import begins.
    private(set) var lastImport: SimklImportSummary?

    /// Mirrors Trakt's durable-history status so a temporary network failure
    /// cannot silently lose a local watched/unwatched choice.
    var pendingMutationCount: Int {
        mutations.pendingCount
    }

    var failedMutationCount: Int {
        mutations.failedCount
    }

    var isSyncingMutations: Bool {
        mutations.isSyncing
    }

    var mutationSyncError: String? {
        mutations.syncError
    }

    /// Durable history and list-status intent — shared with Trakt.
    let mutations: TrackerMutationQueue<SimklAccountBackend>

    private var watchlistTask: Task<[SimklWatchlistEntry], Never>?
    private var watchlistTaskAccount: String?
    private var watchlistTaskID: UUID?

    /// The catalog context the connect flow captured, so the watched-history
    /// import can run the moment the device code is approved.
    private var importContext: ModelContext?

    private let client: SimklClient
    private var scrobbleTask: Task<Void, Never>?

    init(client: SimklClient = .shared, outbox: TrackerMutationOutbox? = nil) {
        self.client = client
        let session = TrackerAccountSession(backend: SimklAccountBackend(client: client))
        self.session = session
        mutations = TrackerMutationQueue(
            session: session,
            outbox: outbox ?? TrackerMutationOutbox(storageKey: SimklAccountBackend.outboxStorageKey)
        )
        mutations.refreshWatchlist = { [weak self] in
            Task { await self?.refreshWatchlistIfNeeded() }
        }
        mutations.didDeliverMutation = { SimklWatchlistStore.clear() }
        session.didConnect = { [weak self] in
            // The account's watched history imports on connect, not only on
            // demand. Runs on the context the connect call captured; the manual
            // re-import stays available for later.
            guard let self, let context = importContext else { return }
            importContext = nil
            await importWatched(into: context)
        }
    }

    /// Whether the build has Simkl credentials at all. When false the whole
    /// integration is hidden.
    var isConfigured: Bool {
        session.isConfigured
    }

    /// Whether this device holds Simkl tokens. The username can lag behind
    /// (after a reinstall it has to be fetched again).
    var isConnected: Bool {
        session.isConnected
    }

    // MARK: - Lifecycle

    /// Restores a previously connected session at launch, or after iCloud
    /// replaced the tokens. Best-effort — offline, the remembered identity
    /// keeps the account connected so watched changes still queue.
    func restore() async {
        guard isConfigured else { return }
        switch await session.restore() {
        case .signedOut:
            // Signed out elsewhere (the credential left through iCloud): the
            // cached watchlist belongs to that account.
            SimklWatchlistStore.clear()
            mutations.refreshStatus()
        case .waiting:
            // Offline, or the refresh was rejected. Keep the pair: the
            // remembered identity still queues changes, and a re-authorized
            // pair may yet arrive through CloudKit.
            break
        case .ready:
            mutations.refreshStatus()
            retryPendingMutations()
        }
    }

    // MARK: - Connect (device flow)

    /// Begins the device-flow connect: requests a code, starts polling, and on
    /// approval imports the account's watched history into the given catalog
    /// context. Passing nil skips the automatic import.
    func connect(into context: ModelContext? = nil) {
        guard !isConnecting else { return }
        importContext = context
        session.connect()
    }

    /// Cancels an in-progress connect.
    func cancelConnect() {
        session.cancelConnect()
        importContext = nil
    }

    // MARK: - Disconnect

    /// Disconnects: revokes the token server-side (best effort) and clears all
    /// local state.
    func disconnect() async {
        watchlistTask?.cancel()
        watchlistTask = nil
        watchlistTaskID = nil
        scrobbleTask?.cancel()
        scrobbleTask = nil
        mutations.reset()
        await session.disconnect()
        // Parked watched state belongs to the account that was just signed out.
        SimklPendingWatchedStore.clearAll()
        SimklWatchlistStore.clear()
        lastImport = nil
        importContext = nil
    }

    // MARK: - Durable watched sync

    /// Queues a movie's watched state for Simkl. Captures the TMDB id up front
    /// so the model never crosses an actor boundary; Simkl resolves the title
    /// from it. No-ops when not connected or the movie has no TMDB id.
    func syncWatched(movie: Movie, watched: Bool) {
        guard let tmdbID = movie.tmdbId else { return }
        mutations.enqueue(.history, .movie(tmdbID: tmdbID), isPresent: watched)
    }

    /// Syncs an episode's watched state to Simkl using its show's TMDB id plus
    /// the season/episode numbers.
    func syncWatched(episode: Episode, watched: Bool) {
        guard let showTMDBID = episode.series?.tmdbId else { return }
        mutations.enqueue(.history, .episode(showTMDBID: showTMDBID, season: episode.seasonNum, episode: episode.episodeNum), isPresent: watched)
    }

    /// Queues removal of a movie's paused progress on Simkl, by TMDB id.
    func clearPausedProgress(movie: Movie) {
        guard let tmdbID = movie.tmdbId else { return }
        mutations.enqueue(.playback, .movie(tmdbID: tmdbID), isPresent: false)
    }

    /// Queues removal of an episode's paused progress on Simkl.
    func clearPausedProgress(episode: Episode) {
        guard let showTMDBID = episode.series?.tmdbId else { return }
        mutations.enqueue(.playback, .episode(showTMDBID: showTMDBID, season: episode.seasonNum, episode: episode.episodeNum), isPresent: false)
    }

    /// Queues a recovered position for Simkl. Durable, unlike a scrobble: it
    /// waits for the account to connect and survives another relaunch.
    func recordPausedProgress(movie: Movie, progress: Double, pausedAt: Date) {
        guard let tmdbID = movie.tmdbId else { return }
        mutations.enqueue(.playback, .movie(tmdbID: tmdbID), isPresent: true, progress: progress, pausedAt: pausedAt)
    }

    func recordPausedProgress(episode: Episode, progress: Double, pausedAt: Date) {
        guard let showTMDBID = episode.series?.tmdbId else { return }
        mutations.enqueue(
            .playback, .episode(showTMDBID: showTMDBID, season: episode.seasonNum, episode: episode.episodeNum),
            isPresent: true, progress: progress, pausedAt: pausedAt
        )
    }

    /// Retries the connected account's durable mutations, oldest first.
    func retryPendingMutations() {
        mutations.retry()
    }

    // MARK: - Playback scrobbling

    /// Sends a start, pause or stop for the connected account, as Trakt's
    /// does: transient, in order, under background time so the stop sent as
    /// the app leaves the foreground still lands. Replaying an old lifecycle
    /// event after relaunch would fake a "watching now" session, so these are
    /// never queued; a crash-recovered position goes through the queue as a
    /// pause instead (`recordPausedProgress`).
    func scrobble(_ target: TraktScrobbleTarget, action: TraktScrobbleAction, progress: Double) {
        guard isConnected else { return }
        let previous = scrobbleTask
        let permit = session.operationPermit
        let backgroundTime = ScrobbleBackgroundTime.begin()
        scrobbleTask = Task { [weak self] in
            defer { backgroundTime.end() }
            await previous?.value
            guard !Task.isCancelled, let self, permit.isCurrent else { return }
            guard let accessToken = await permit.accessToken(using: session.operationAccessToken) else {
                Logger.network.warning("Simkl scrobble \(action.rawValue, privacy: .public) dropped: no valid access token")
                return
            }
            do {
                let recorded = try await client.scrobble(target, action: action, progress: progress, accessToken: accessToken)
                Logger.network.info(
                    "Simkl scrobble \(action.rawValue, privacy: .public) at \(progress, format: .fixed(precision: 1))% → recorded \(recorded.action ?? "?", privacy: .public)"
                )
            } catch {
                let detail = LogRedaction.describe(error)
                Logger.network.warning(
                    "Simkl scrobble \(action.rawValue, privacy: .public) at \(progress, format: .fixed(precision: 1))% failed: \(detail, privacy: .public)"
                )
            }
        }
    }

    // MARK: - Watchlist

    /// On adds to Plan to Watch; off moves to Dropped without erasing history.
    func syncWatchlist(movie: Movie, watchlisted: Bool) {
        guard let tmdbID = movie.tmdbId else { return }
        mutations.enqueue(.watchlist, .movie(tmdbID: tmdbID), isPresent: watchlisted)
    }

    func syncWatchlist(series: Series, watchlisted: Bool) {
        guard let tmdbID = series.tmdbId else { return }
        mutations.enqueue(.watchlist, .show(tmdbID: tmdbID), isPresent: watchlisted)
    }

    func refreshWatchlistIfNeeded() async {
        guard let account = mutations.account else { return }
        mutations.watchlist.reset(account: account)
        guard mutations.watchlist.needsRefresh else { return }
        let revision = mutations.watchlist.revision
        _ = await fetchWatchlist()
        if mutations.account == account, mutations.watchlist.revision != revision, mutations.watchlist.needsRefresh {
            _ = await fetchWatchlist()
        }
    }

    /// The user's "Plan to Watch" titles, most recently added first. Served
    /// from the on-disk copy, refetching only the buckets `/sync/activities`
    /// says have moved (see `SimklWatchlist.swift`). Returns an empty array when
    /// not connected; on error it falls back to the cached copy, so the home row
    /// keeps what it last showed rather than blinking out.
    func fetchWatchlist() async -> [SimklWatchlistEntry] {
        guard let account = mutations.account else { return [] }
        if let watchlistTask, watchlistTaskAccount == account {
            return await watchlistTask.value
        }
        mutations.watchlist.reset(account: account)
        let revision = mutations.watchlist.revision
        let id = UUID()
        let task = Task { [weak self] () -> [SimklWatchlistEntry] in
            guard let self else { return [] }
            defer {
                if watchlistTaskID == id { watchlistTask = nil; watchlistTaskID = nil }
            }
            let result = await loadWatchlist()
            guard mutations.account == account, watchlistTaskID == id else { return [] }
            mutations.updateWatchlist(Set(result.map(\.target)), account: account, revision: revision)
            return result
        }
        watchlistTask = task
        watchlistTaskAccount = account
        watchlistTaskID = id
        return await task.value
    }

    private func loadWatchlist() async -> [SimklWatchlistEntry] {
        guard let account = mutations.account, let username, let accessToken = await session.validAccessToken(), mutations.account == account else { return [] }
        let revision = mutations.watchlist.revision
        var cache = SimklWatchlistStore.load(for: username) ?? SimklWatchlistCache(username: username)
        let activities: SimklActivities
        do {
            activities = try await client.activities(accessToken: accessToken)
        } catch {
            Logger.network.warning("Simkl watchlist activities failed; keeping \(cache.entries.count) cached entries: \(LogRedaction.describe(error), privacy: .public)")
            return cache.entries
        }
        let original = cache
        for bucket in cache.staleBuckets(for: activities) {
            guard let fingerprint = activities.fingerprint(for: bucket) else {
                cache.buckets[bucket] = SimklWatchlistCache.Bucket(fingerprint: nil, entries: [])
                continue
            }
            // A failed bucket keeps its old copy and fingerprint, so the next
            // Home load retries it.
            let entries: [SimklWatchlistEntry]
            do {
                entries = try await client.planToWatch(bucket, accessToken: accessToken)
            } catch {
                Logger.network.warning("Simkl watchlist bucket request failed; keeping cached entries: \(LogRedaction.describe(error), privacy: .public)")
                continue
            }
            cache.buckets[bucket] = SimklWatchlistCache.Bucket(fingerprint: fingerprint, entries: entries)
        }
        // A disconnect mid-fetch already cleared the store; writing now would
        // resurrect the signed-out account's list.
        guard mutations.account == account, self.username == username else { return [] }
        if cache != original, mutations.watchlist.revision == revision {
            SimklWatchlistStore.save(cache)
        }
        return cache.entries
    }

    // MARK: - Watched import

    /// Imports the user's Simkl watched history into the local catalog, marking
    /// matching movies and episodes as watched. Writes through `context` (the
    /// catalog container's context the UI binds to); the iCloud reconciler then
    /// mirrors the change to the user's other devices. No-ops when not connected
    /// or an import is already running.
    func importWatched(into context: ModelContext) async {
        guard isConnected, !isImporting else { return }
        isImporting = true
        lastImport = nil
        defer { isImporting = false }

        // Same scope rule as Trakt: local changes go up first, and the history
        // is applied only to the account and profile it was fetched for.
        let container = context.container
        let outcome = await TrackerImportRun(
            permit: session.importPermit,
            begin: { await TrackerScope.begin(after: self.mutations) },
            accessToken: { await self.session.validAccessToken() },
            fetch: { try await self.client.watchedItems(accessToken: $0) },
            isCurrent: { $0.isCurrent(isConnected: self.isConnected, account: self.mutations.account, pendingCount: self.mutations.pendingCount) },
            apply: { items, scope, permit in await Self.applyImport(items: items, container: container, scope: scope, permit: permit) }
        ).perform()
        switch outcome {
        case .deferred:
            Logger.network.info("Simkl history import deferred: pending local changes or changed scope")
        case let .failed(failure):
            Logger.network.warning("Simkl history import failed: \(failure.logDescription, privacy: .public)")
            lastImport = .failure
        case .discarded:
            Logger.network.info("Simkl history import discarded: account, profile or pending changes moved during the fetch")
        case let .applied(summary):
            lastImport = summary
        }
    }

    /// Off the main actor, on a context of its own — see `TraktService`.
    @concurrent
    static func applyImport(items: SimklAllItems, container: ModelContainer, scope: TrackerScope, permit: TrackerImportPermit) async -> SimklImportSummary {
        await TrackerImportPages.apply(
            SimklHistoryPage.plan(items), scope: .init(container: container, permit: permit, isCurrent: { scope.matches(.simkl) }),
            initial: SimklImportSummary()
        ) { page, context in page.apply(in: context, scope: scope) }
    }
}

extension Notification.Name {
    /// Posted only for local Simkl authorization changes. CloudKit pulls do not
    /// repost it, preventing an import/export feedback loop.
    static let lumeSimklCredentialsDidChange = Notification.Name("LumeSimklCredentialsDidChange")
}
