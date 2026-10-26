//
//  MDBListService.swift
//  Lume
//
//  The app-wide coordinator for the MDBList integration, a third tracker
//  beside Trakt and Simkl with the same shape: the shared sign-in and token
//  lifecycle (`TrackerAccountSession`), durable watched, paused-progress and
//  watchlist changes and the watchlist read for Home and the heart
//  (`TrackerMutationQueue`), transient playback scrobbles, and the
//  watched-history import.
//
//  A shared singleton because watched-state changes originate from many places
//  (player completion, detail-screen toggles, model methods) that don't all
//  have access to the SwiftUI environment. It's still `@Observable`, so views
//  observe `MDBListService.shared` directly.
//

import Foundation
import OSLog
import SwiftData

@MainActor
@Observable
final class MDBListService {
    static let shared = MDBListService()

    /// Sign-in and tokens — shared with Trakt and Simkl.
    let session: TrackerAccountSession<MDBListAccountBackend>

    /// Durable history, paused-progress and watchlist intent — shared with
    /// Trakt and Simkl.
    let mutations: TrackerMutationQueue<MDBListAccountBackend>

    /// The connected MDBList username, or nil when signed out or not yet known.
    var username: String? {
        session.username
    }

    /// The in-flight device code while the user is approving authorization.
    var pendingCode: MDBListDeviceCode? {
        session.pendingCode
    }

    var connectionError: String? {
        session.connectionError
    }

    var isConnecting: Bool {
        session.isConnecting
    }

    /// Whether the build has an MDBList client id at all. When false the whole
    /// integration is hidden.
    var isConfigured: Bool {
        session.isConfigured
    }

    /// Whether this device holds MDBList tokens. The username can lag behind.
    var isConnected: Bool {
        session.isConnected
    }

    /// Whether a watched-history import is currently running.
    private(set) var isImporting = false

    /// The result of the most recent import, surfaced in the Settings UI.
    private(set) var lastImport: TrackerWatchedImportSummary?

    var pendingMutationCount: Int {
        mutations.pendingCount
    }

    var isSyncingMutations: Bool {
        mutations.isSyncing
    }

    var mutationSyncError: String? {
        mutations.syncError
    }

    /// The catalog context the connect flow captured, so the watched-history
    /// import can run the moment the device code is approved.
    private var importContext: ModelContext?

    private let client: MDBListSyncClient
    private var scrobbleTask: Task<Void, Never>?

    init(client: MDBListSyncClient = .shared, outbox: TrackerMutationOutbox? = nil) {
        self.client = client
        let session = TrackerAccountSession(backend: MDBListAccountBackend(client: client))
        self.session = session
        mutations = TrackerMutationQueue(
            session: session,
            outbox: outbox ?? TrackerMutationOutbox(storageKey: MDBListAccountBackend.outboxStorageKey)
        )
        mutations.fetchWatchlist = { accessToken in
            try await client.watchlist(accessToken: accessToken).map { TrackerWatchlistEntry(target: $0.target) }
        }
        session.didConnect = { [weak self] in
            // The account's watched history imports on connect, as Simkl's
            // does; the manual re-import stays available for later.
            guard let self, let context = importContext else { return }
            importContext = nil
            await importWatched(into: context)
        }
    }

    // MARK: - Lifecycle

    /// Restores a previously connected session at launch. Best-effort —
    /// offline, the remembered identity keeps the account connected so watched
    /// changes still queue.
    func restore() async {
        guard isConfigured else { return }
        switch await session.restore() {
        case .signedOut:
            mutations.refreshStatus()
        case .waiting:
            break
        case .ready:
            mutations.refreshStatus()
            retryPendingMutations()
        }
    }

    /// Begins the device-flow connect; on approval imports the account's
    /// watched history into `context`. Passing nil skips the import.
    func connect(into context: ModelContext? = nil) {
        guard !isConnecting else { return }
        importContext = context
        session.connect()
    }

    func cancelConnect() {
        session.cancelConnect()
        importContext = nil
    }

    /// Revokes the token server-side (best effort) and clears all local state.
    func disconnect() async {
        scrobbleTask?.cancel()
        scrobbleTask = nil
        mutations.reset()
        await session.disconnect()
        // Parked watched state belongs to the account that was just signed out.
        MDBListPendingWatchedStore.clearAll()
        lastImport = nil
        importContext = nil
    }

    // MARK: - Durable watched sync

    func syncWatched(movie: Movie, watched: Bool) {
        guard let tmdbID = movie.tmdbId else { return }
        mutations.enqueue(.history, .movie(tmdbID: tmdbID), isPresent: watched)
    }

    func syncWatched(episode: Episode, watched: Bool) {
        guard let showTMDBID = episode.series?.tmdbId else { return }
        mutations.enqueue(.history, .episode(showTMDBID: showTMDBID, season: episode.seasonNum, episode: episode.episodeNum), isPresent: watched)
    }

    func clearPausedProgress(movie: Movie) {
        guard let tmdbID = movie.tmdbId else { return }
        mutations.enqueue(.playback, .movie(tmdbID: tmdbID), isPresent: false)
    }

    func clearPausedProgress(episode: Episode) {
        guard let showTMDBID = episode.series?.tmdbId else { return }
        mutations.enqueue(.playback, .episode(showTMDBID: showTMDBID, season: episode.seasonNum, episode: episode.episodeNum), isPresent: false)
    }

    /// Queues a recovered position. Durable, unlike a scrobble: it waits for
    /// the account to connect and survives another relaunch.
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

    func retryPendingMutations() {
        mutations.retry()
    }

    // MARK: - Playback scrobbling

    /// Sends a start, pause or stop for the connected account, as Simkl's
    /// does: transient, in order, under background time so the stop sent as
    /// the app leaves the foreground still lands. Never queued — replaying an
    /// old event after relaunch would fake a "watching now" session.
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
                Logger.network.warning("MDBList scrobble \(action.rawValue, privacy: .public) dropped: no valid access token")
                return
            }
            do {
                let recorded = try await client.scrobble(target, action: action, progress: progress, accessToken: accessToken)
                Logger.network.info(
                    "MDBList scrobble \(action.rawValue, privacy: .public) at \(progress, format: .fixed(precision: 1))% → recorded \(recorded?.action ?? "?", privacy: .public)"
                )
            } catch {
                let detail = LogRedaction.describe(error)
                Logger.network.warning(
                    "MDBList scrobble \(action.rawValue, privacy: .public) at \(progress, format: .fixed(precision: 1))% failed: \(detail, privacy: .public)"
                )
            }
        }
    }

    // MARK: - Watched import

    /// Imports the account's watched history into the local catalog, marking
    /// matching movies and episodes as watched. No-ops when not connected or
    /// an import is already running.
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
            fetch: { try await self.client.watchedHistory(accessToken: $0) },
            isCurrent: { $0.isCurrent(isConnected: self.isConnected, account: self.mutations.account, pendingCount: self.mutations.pendingCount) },
            apply: { history, scope, permit in await Self.applyImport(history: history, container: container, scope: scope, permit: permit) }
        ).perform()
        switch outcome {
        case .deferred:
            Logger.network.info("MDBList history import deferred: pending local changes or changed scope")
        case let .failed(failure):
            Logger.network.warning("MDBList history import failed: \(failure.logDescription, privacy: .public)")
            lastImport = .failure
        case .discarded:
            Logger.network.info("MDBList history import discarded: account, profile or pending changes moved during the fetch")
        case let .applied(summary):
            lastImport = summary
        }
    }

    /// Off the main actor, on a context of its own — see `TraktService`.
    @concurrent
    static func applyImport(
        history: MDBListWatchedHistory, container: ModelContainer, scope: TrackerScope, permit: TrackerImportPermit
    ) async -> TrackerWatchedImportSummary {
        await TrackerImportPages.apply(
            MDBListHistoryPage.plan(MDBListWatchedImporter.history(history)),
            scope: .init(container: container, permit: permit, isCurrent: { scope.matches(.mdblist) }),
            initial: TrackerWatchedImportSummary()
        ) { page, context in page.apply(in: context, scope: scope) }
    }
}
