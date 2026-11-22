//
//  PlaylistSyncMachine.swift
//  Lume
//
//  The rules of the playlist sync queue, as a value: what is waiting, what is
//  running, how the last sync ended, and which playlists this session has
//  already given an automatic attempt or area repair. `PlaylistSyncCenter`
//  owns one and does the running; keeping the decisions here means every
//  ordering, dedupe and retry rule is tested without SwiftUI, SwiftData or a
//  network.
//
//  What to sync is decided before a job gets here, by `AutoSync.plan` for the
//  automatic ones and by the viewer for the rest.
//

import Foundation

/// One playlist sync. A value on purpose: the playlist can be deleted while
/// its sync is on screen, and the queue never holds a model object.
struct PlaylistSyncJob: Identifiable, Equatable {
    enum Origin: Equatable {
        /// Due on its own (launch, foreground, playlist or profile switch) or
        /// an area repair.
        case automatic
        /// Asked for by the viewer.
        case manual
    }

    let playlistID: UUID
    let name: String
    let plan: PlaylistSyncPlan
    let origin: Origin
    /// The playlist has never finished a sync, so its tabs have nothing to
    /// show until this one lands.
    let isFirstImport: Bool
    /// Every area this run repairs already has rows to browse. Only an
    /// automatic repair sets it (`AutoSync.Plan.runsInBackground`).
    var refreshesBrowsableAreas = false
    /// Recorded in the repair ledger when the job is queued.
    var repairedAreas: Set<AppArea> = []

    var id: UUID {
        playlistID
    }

    var isManual: Bool {
        origin == .manual
    }

    /// Someone is waiting on this one: they asked for it, or there is nothing
    /// to browse until it finishes. Anything else refreshes rows the viewer
    /// can already use and gives way to them.
    var isAwaited: Bool {
        isManual || isFirstImport || (plan.repairingAreas != nil && !refreshesBrowsableAreas)
    }

    /// The same sync, asked for again by the viewer (Try Again).
    var retried: PlaylistSyncJob {
        PlaylistSyncJob(playlistID: playlistID, name: name, plan: plan, origin: .manual, isFirstImport: isFirstImport)
    }
}

struct PlaylistSyncMachine {
    /// How a sync ended. A stopped sync leaves none.
    struct Outcome: Equatable {
        let job: PlaylistSyncJob
        /// `nil` when it succeeded.
        let failure: String?
        let finishedAt: Date

        var failed: Bool {
            failure != nil
        }
    }

    enum Result: Equatable {
        case succeeded
        case failed(String)
        case stopped
    }

    private(set) var pending: [PlaylistSyncJob] = []
    private(set) var running: PlaylistSyncJob?
    /// The last sync to finish, until another finishes or the viewer has seen
    /// it.
    private(set) var recent: Outcome?
    /// Playlists given their regular automatic attempt this session, so the
    /// launch / switch / foreground triggers don't queue one twice.
    private(set) var attempted: Set<UUID> = []
    /// Areas each playlist has had an automatic repair for this session.
    private(set) var repairLedger = AutoSync.RepairLedger()
    private var runningWasReconnected = false

    var isBusy: Bool {
        running != nil || !pending.isEmpty
    }

    func isQueued(_ playlistID: UUID) -> Bool {
        running?.playlistID == playlistID || pending.contains { $0.playlistID == playlistID }
    }

    func isSyncing(anyOf playlistIDs: Set<UUID>) -> Bool {
        if let running, playlistIDs.contains(running.playlistID) { return true }
        return pending.contains { playlistIDs.contains($0.playlistID) }
    }

    /// The last sync's failure while nothing is running, if it was one of
    /// `playlistIDs` (any playlist when `nil`).
    func recentFailure(in playlistIDs: Set<UUID>? = nil) -> Outcome? {
        guard running == nil, let recent, recent.failed else { return nil }
        if let playlistIDs, !playlistIDs.contains(recent.job.playlistID) { return nil }
        return recent
    }

    // MARK: Queueing

    /// Queues `job` unless its playlist is already queued or running, and
    /// returns whether it did. A manual job goes ahead of every automatic one
    /// waiting, behind any manual ones before it; asking for a playlist that
    /// is only waiting automatically moves it up instead.
    @discardableResult
    mutating func enqueue(_ job: PlaylistSyncJob) -> Bool {
        if job.origin == .automatic {
            attempted.insert(job.playlistID)
            repairLedger.record(job.repairedAreas, for: job.playlistID)
        }
        if running?.playlistID == job.playlistID { return false }
        if let index = pending.firstIndex(where: { $0.playlistID == job.playlistID }) {
            guard job.isManual, !pending[index].isManual else { return false }
            pending.remove(at: index)
        }
        let position = job.isManual ? (pending.firstIndex { !$0.isManual } ?? pending.endIndex) : pending.endIndex
        pending.insert(job, at: position)
        return true
    }

    /// Starts the next job when nothing is running.
    mutating func startNext() -> PlaylistSyncJob? {
        guard running == nil, !pending.isEmpty else { return nil }
        let job = pending.removeFirst()
        running = job
        runningWasReconnected = false
        return job
    }

    /// Returns a playlist to plan again when its in-flight connection was
    /// replaced before that attempt failed. Success and an explicit stop do
    /// not repeat work.
    @discardableResult
    mutating func finish(_ result: Result, at date: Date = Date()) -> UUID? {
        guard let job = running else { return nil }
        let reconnected = runningWasReconnected
        runningWasReconnected = false
        running = nil
        switch result {
        case .succeeded: recent = Outcome(job: job, failure: nil, finishedAt: date)
        case let .failed(message): recent = Outcome(job: job, failure: message, finishedAt: date)
        case .stopped: if recent?.job.playlistID == job.playlistID { recent = nil }
        }
        if reconnected, case .failed = result {
            attempted.remove(job.playlistID)
            repairLedger.reset(job.playlistID)
            recent = nil
            return job.playlistID
        }
        return nil
    }

    /// Queues the last failed sync again, ahead of the automatic ones.
    mutating func retryRecent() -> Bool {
        guard let failure = recentFailure() else { return false }
        recent = nil
        return enqueue(failure.job.retried)
    }

    mutating func acknowledgeRecent() {
        if running == nil { recent = nil }
    }

    /// Forgets syncs of playlists that no longer exist. Returns whether the
    /// running one was among them, for the owner to stop.
    mutating func dropSyncs(notIn playlistIDs: Set<UUID>) -> Bool {
        pending.removeAll { !playlistIDs.contains($0.playlistID) }
        if let recent, !playlistIDs.contains(recent.job.playlistID) { self.recent = nil }
        return running.map { !playlistIDs.contains($0.playlistID) } ?? false
    }

    // MARK: Session attempts

    func wasAttempted(_ playlistID: UUID) -> Bool {
        attempted.contains(playlistID)
    }

    /// iCloud brought new connection details for `reconnectedIDs`. Those whose
    /// sync failed this session get their automatic attempt and repairs back.
    /// Returns the ones to plan again: all of them but any already queued,
    /// which will run against the new details anyway.
    mutating func reconnected(_ reconnectedIDs: Set<UUID>, failedIDs: Set<UUID>) -> Set<UUID> {
        if let running, reconnectedIDs.contains(running.playlistID) { runningWasReconnected = true }
        var failed = failedIDs
        if let failure = recentFailure() { failed.insert(failure.job.playlistID) }
        let reset = reconnectedIDs.intersection(failed)
        for id in reset {
            attempted.remove(id)
            repairLedger.reset(id)
            if recent?.job.playlistID == id { recent = nil }
        }
        return reset.filter { !isQueued($0) }
    }
}
