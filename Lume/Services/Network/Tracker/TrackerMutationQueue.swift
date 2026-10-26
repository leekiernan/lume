//
//  TrackerMutationQueue.swift
//  Lume
//
//  Delivers a tracker account's durable changes (watched, watchlisted) from
//  its `TrackerMutationOutbox`, shared by the Trakt and Simkl services.
//
//  Strictly oldest-first: one failure stops the drain, so a later change can
//  never overtake an earlier one for the same title. A change the service has
//  no request for is dropped rather than left to block the queue. Changes are
//  partitioned by the account's scope, so they only drain once the session
//  knows who the tokens belong to — and a remembered identity queues them,
//  while only a confirmed one (fetched with a working token) sends them.
//
//  It also reads the account's watchlist for Home and the heart
//  (`watchlistEntries()`): the tracker supplies the fetch, and everything
//  around it — sharing a read, rejecting one a change has overtaken, the saved
//  copy behind an offline launch — is the same for every tracker.
//

import Foundation
import OSLog

@MainActor
@Observable
final class TrackerMutationQueue<Backend: TrackerAccountBackend> {
    private(set) var pendingCount = 0
    private(set) var failedCount = 0
    private(set) var isSyncing = false
    private(set) var syncError: String?
    let watchlist = TrackerWatchlistMembership()
    /// The tracker's own watchlist request, newest first or in the tracker's
    /// order, given a valid access token. Set once by the service.
    @ObservationIgnored var fetchWatchlist: ((String) async throws -> [TrackerWatchlistEntry])?
    @ObservationIgnored var didDeliverMutation: (() -> Void)?

    @ObservationIgnored private let session: TrackerAccountSession<Backend>
    @ObservationIgnored private let outbox: TrackerMutationOutbox
    @ObservationIgnored private var drainTask: Task<Void, Never>?
    @ObservationIgnored private var drainID: UUID?
    /// The watchlist read in flight, and the account and membership revision
    /// it began under: only a caller at the same revision may share it.
    @ObservationIgnored private var watchlistRead: (account: String, revision: UUID, id: UUID, task: Task<[TrackerWatchlistEntry], Error>)?

    /// Takes over the session's `identityDidChange` hook: identity is what
    /// scopes and releases the queue.
    init(session: TrackerAccountSession<Backend>, outbox: TrackerMutationOutbox) {
        self.session = session
        self.outbox = outbox
        session.identityDidChange = { [weak self] identity, confirmed in
            self?.identityDidChange(identity, confirmed: confirmed)
        }
    }

    /// The connected account's partition, once its identity is known.
    var account: String? {
        guard session.isConnected, let scope = session.identity?.scope, !scope.isEmpty else { return nil }
        return scope
    }

    /// Records the user's intent and starts sending it. A no-op until the
    /// account is known.
    func enqueue(
        _ kind: TrackerMutation.Kind, _ target: TrackerMutation.Target, isPresent: Bool,
        progress: Double? = nil, pausedAt: Date? = nil
    ) {
        guard let account else { return }
        outbox.enqueue(kind: kind, target: target, isPresent: isPresent, account: account, progress: progress, pausedAt: pausedAt)
        if kind == .watchlist {
            prepareWatchlist()
            watchlist.apply(target, isPresent: isPresent)
        }
        refreshStatus()
        retry()
    }

    /// Sends the connected account's queued changes. A no-op while a drain is
    /// already running.
    func retry() {
        guard drainTask == nil, let account, outbox.firstMutation(account: account) != nil else {
            refreshStatus()
            return
        }
        syncError = nil
        isSyncing = true
        let id = UUID()
        drainID = id
        drainTask = Task { [weak self] in
            await self?.drain(account: account, id: id)
        }
    }

    /// Imports must not race ahead of this device's durable intent. Await the
    /// existing drain rather than starting another delivery loop. Failed work
    /// stays queued; callers can defer their import instead of overwriting it.
    func flush() async {
        retry()
        await drainTask?.value
        refreshStatus()
    }

    func refreshStatus() {
        guard let account else {
            pendingCount = 0
            failedCount = 0
            syncError = nil
            return
        }
        let status = outbox.status(account: account)
        pendingCount = status.pendingCount
        failedCount = status.failedCount
        if status.failedCount == 0 {
            syncError = nil
        } else if syncError == nil {
            syncError = "Some \(Backend.name) changes are waiting to retry."
        }
    }

    /// Stops sending and clears the status, on disconnect. The account's
    /// queued changes stay, partitioned under its scope.
    func reset() {
        watchlist.reset(account: nil)
        watchlistRead?.task.cancel()
        watchlistRead = nil
        TrackerWatchlistStore.clear(Backend.name)
        drainTask?.cancel()
        drainTask = nil
        drainID = nil
        isSyncing = false
        pendingCount = 0
        failedCount = 0
        syncError = nil
    }

    private func identityDidChange(_ identity: Backend.Identity?, confirmed: Bool) {
        if let identity {
            for previous in identity.previousScopes {
                outbox.adoptMutations(from: previous, into: identity.scope)
            }
        }
        refreshStatus()
        prepareWatchlist()
        if confirmed {
            retry()
            refreshWatchlistSoon()
        }
    }

    func isWatchlisted(_ target: TrackerMutation.Target) -> Bool {
        guard let account else { return false }
        if let intent = outbox.mutations(account: account).last(where: { $0.kind == .watchlist && $0.target == target }) {
            return intent.isPresent
        }
        return watchlist.contains(target, account: account)
    }

    func updateWatchlist(_ targets: Set<TrackerMutation.Target>, account: String, revision: UUID) {
        guard self.account == account else { return }
        var targets = targets
        for mutation in outbox.mutations(account: account) where mutation.kind == .watchlist {
            if mutation.isPresent { targets.insert(mutation.target) } else { targets.remove(mutation.target) }
        }
        watchlist.replace(with: targets, account: account, revision: revision)
    }

    // MARK: - Watchlist reads

    /// Points membership at the connected account. A launch, or a switch to
    /// another account, starts from that account's saved read, still due a
    /// refresh, so the heart is right before — or without — the network.
    private func prepareWatchlist() {
        let previous = watchlist.account
        watchlist.reset(account: account)
        guard let account, watchlist.account != previous,
              let saved = TrackerWatchlistStore.load(Backend.name, account: account) else { return }
        watchlist.seed(Set(saved.map(\.target)))
    }

    private func refreshWatchlistSoon() {
        Task { [weak self] in await self?.refreshWatchlistIfNeeded() }
    }

    /// Reads the watchlist unless a recent read still stands. A change
    /// delivered while the read ran retires it; read once more if so.
    func refreshWatchlistIfNeeded() async {
        guard let account else { return }
        prepareWatchlist()
        guard watchlist.needsRefresh else { return }
        let revision = watchlist.revision
        _ = try? await watchlistEntries()
        if self.account == account, watchlist.revision != revision, watchlist.needsRefresh {
            _ = try? await watchlistEntries()
        }
    }

    /// The watchlist, read through the tracker's `fetchWatchlist`. Concurrent
    /// callers share one read — but only one begun at the current membership
    /// revision, since a read a change has overtaken can't update membership.
    /// When the tracker can't be reached, the last good read stands in.
    func watchlistEntries() async throws -> [TrackerWatchlistEntry] {
        guard let account, let fetchWatchlist else { throw TrackerWatchlistError.notConnected }
        prepareWatchlist()
        let revision = watchlist.revision
        if let read = watchlistRead, read.account == account, read.revision == revision {
            return try await read.task.value
        }
        let id = UUID()
        let task = Task { [weak self] () throws -> [TrackerWatchlistEntry] in
            guard let self else { throw TrackerWatchlistError.notConnected }
            defer {
                if watchlistRead?.id == id { watchlistRead = nil }
            }
            guard let accessToken = await session.validAccessToken(), self.account == account else {
                throw TrackerWatchlistError.notConnected
            }
            let entries: [TrackerWatchlistEntry]
            do {
                entries = try await fetchWatchlist(accessToken)
            } catch {
                Logger.network.warning("\(Backend.name, privacy: .public) watchlist request failed: \(LogRedaction.describe(error), privacy: .public)")
                guard let saved = TrackerWatchlistStore.load(Backend.name, account: account) else { throw error }
                return saved
            }
            guard self.account == account else { throw TrackerWatchlistError.notConnected }
            updateWatchlist(Set(entries.map(\.target)), account: account, revision: revision)
            // Only a read nothing has overtaken describes the account now.
            if watchlist.revision == revision {
                TrackerWatchlistStore.save(Backend.name, account: account, entries: entries)
            }
            return entries
        }
        watchlistRead = (account, revision, id, task)
        return try await task.value
    }

    private func drain(account: String, id: UUID) async {
        defer {
            if drainID == id {
                drainTask = nil
                drainID = nil
                isSyncing = false
                refreshStatus()
            }
        }

        while !Task.isCancelled, self.account == account, let mutation = outbox.firstMutation(account: account) {
            guard let accessToken = await session.validAccessToken() else {
                guard !Task.isCancelled, drainID == id, self.account == account else { break }
                outbox.recordFailure(id: mutation.id, account: account)
                syncError = "Couldn't sync changes to \(Backend.name). Please try again."
                break
            }
            guard !Task.isCancelled, drainID == id, self.account == account else { break }
            do {
                guard try await session.backend.deliver(mutation, accessToken: accessToken) else {
                    Logger.network.error(
                        "Discarding \(Backend.name) \(mutation.kind.rawValue) mutation it has no request for"
                    )
                    outbox.acknowledge(id: mutation.id, account: account)
                    continue
                }
                outbox.acknowledge(id: mutation.id, account: account)
                if self.account == account {
                    didDeliverMutation?()
                    watchlist.invalidate()
                    refreshWatchlistSoon()
                }
            } catch {
                outbox.recordFailure(id: mutation.id, account: account)
                Logger.network.warning("\(Backend.name, privacy: .public) \(mutation.kind.rawValue, privacy: .public) mutation failed: \(LogRedaction.describe(error), privacy: .public)")
                syncError = "Couldn't sync changes to \(Backend.name). Please try again."
                // Replaced while its request was in flight, it is no longer the
                // head: carry on with the newer intent. Otherwise keep strict
                // FIFO and wait for a retry.
                if outbox.contains(id: mutation.id, account: account) {
                    break
                }
            }
        }
    }
}
