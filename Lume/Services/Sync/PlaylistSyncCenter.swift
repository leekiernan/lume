//
//  PlaylistSyncCenter.swift
//  Lume
//
//  Owns every playlist sync the app runs: the automatic ones `MainTabView`
//  asks for on launch, foreground and playlist or profile switches, area
//  repairs, retries after iCloud brings new connection details, and the ones
//  the viewer starts from the library toolbar or a playlist's settings. They
//  run one at a time, always behind the library; nothing here takes the
//  screen. The toolbar ring, the empty-tab placeholders and the activity sheet
//  only read it.
//
//  Main-actor `@Observable` because SwiftUI reads it synchronously; the sync
//  itself runs in `ContentSyncManager`, an actor, through `PlaylistSyncRun`.
//  The queue's rules are `PlaylistSyncMachine`'s.
//

import Foundation
import Observation
import OSLog
import SwiftData

@Observable
final class PlaylistSyncCenter {
    /// Runs one sync. `PlaylistSyncRun.perform` in the app; tests supply their own.
    typealias Runner = (_ playlist: Playlist, _ container: ModelContainer, _ plan: PlaylistSyncPlan, _ progress: SyncProgress) async throws -> Void

    private(set) var machine = PlaylistSyncMachine()
    /// The running sync's progress, then the last finished one's.
    private(set) var progress: SyncProgress?

    @ObservationIgnored private let container: ModelContainer
    @ObservationIgnored private let run: Runner
    @ObservationIgnored private let busyChanged: (Bool) -> Void
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var reportedBusy = false
    @ObservationIgnored private var automaticScope: (activePlaylistID: String, disabledAreas: DisabledAreas)?
    /// UI tests seed a playlist against a stub server; an automatic sync could
    /// never succeed there, so only the ones the test asks for run.
    @ObservationIgnored private let runsAutomaticSyncs: Bool

    init(
        container: ModelContainer,
        runsAutomaticSyncs: Bool = !CommandLine.arguments.contains("-ui-testing"),
        busyChanged: ((Bool) -> Void)? = nil,
        run: Runner? = nil
    ) {
        self.container = container
        self.runsAutomaticSyncs = runsAutomaticSyncs
        // The guide refresh shares the provider's connections with these syncs
        // and holds back while any is waiting (`EPGRefreshGate`).
        self.busyChanged = busyChanged ?? { EPGSyncService.shared.setAutoSyncQueued($0) }
        self.run = run ?? { playlist, container, plan, progress in
            try await PlaylistSyncRun.perform(playlist, container: container, plan: plan, progress: progress)
        }
    }

    // MARK: Reading

    var running: PlaylistSyncJob? {
        machine.running
    }

    var recent: PlaylistSyncMachine.Outcome? {
        machine.recent
    }

    var upNext: [PlaylistSyncJob] {
        machine.pending
    }

    var isBusy: Bool {
        machine.isBusy
    }

    func isSyncing(_ playlistID: UUID?) -> Bool {
        playlistID.map { machine.isSyncing(anyOf: [$0]) } ?? false
    }

    func recentFailure(for playlistID: UUID? = nil) -> PlaylistSyncMachine.Outcome? {
        machine.recentFailure(in: playlistID.map { [$0] })
    }

    /// Whether `playlistID` is in its first import and hasn't finished `step`,
    /// the one that fills a tab. That tab then shows the sync instead of
    /// category shells with nothing in them.
    func isFirstImportAwaiting(_ step: SyncStep, playlistID: UUID?) -> Bool {
        guard let running, running.isFirstImport, running.playlistID == playlistID, let progress else { return false }
        return progress.isAwaiting(step)
    }

    // MARK: Automatic syncs

    /// Queues each of `candidates` that is due, or missing an area the active
    /// profile enables (`AutoSync.plan`). Only the playlist on screen, or one
    /// just added, earns automatic work; any other syncs when the viewer
    /// switches to it.
    func enqueueDue(_ candidates: [Playlist], activePlaylistID: String, disabledAreas: DisabledAreas) {
        guard runsAutomaticSyncs else { return }
        automaticScope = (activePlaylistID, disabledAreas)
        for playlist in candidates where !machine.isQueued(playlist.id) {
            guard let job = automaticJob(for: playlist, activePlaylistID: activePlaylistID, disabledAreas: disabledAreas) else { continue }
            machine.enqueue(job)
        }
        startNextIfIdle()
    }

    /// iCloud brought new connection details for these playlists. Any whose
    /// sync failed this session against the old ones is planned again.
    func reconnected(_ ids: Set<UUID>, playlists: [Playlist], activePlaylistID: String, disabledAreas: DisabledAreas) {
        let failed = Set(playlists.filter { $0.syncStatus == .error }.map(\.id))
        let retry = machine.reconnected(ids, failedIDs: failed)
        enqueueDue(playlists.filter { retry.contains($0.id) }, activePlaylistID: activePlaylistID, disabledAreas: disabledAreas)
    }

    private func automaticJob(for playlist: Playlist, activePlaylistID: String, disabledAreas: DisabledAreas) -> PlaylistSyncJob? {
        let context = container.mainContext
        PlaylistSyncCoverage.bootstrapFromCatalogIfNeeded(playlistID: playlist.id, lastSyncDate: playlist.lastSyncDate, context: context)
        let input = AutoSync.PlanInput(
            candidate: playlist.autoSyncCandidate(activeID: activePlaylistID),
            playlistID: playlist.id,
            frequency: playlist.syncFrequency,
            alreadyStarted: machine.wasAttempted(playlist.id),
            staleAreas: PlaylistSyncCoverage.missingAreasForAutomaticRepair(
                playlistID: playlist.id, disabledAreas: disabledAreas, frequency: playlist.syncFrequency
            ),
            supportsAreaRepair: playlist.sourceType == .xtream
        )
        guard let plan = AutoSync.plan(
            input,
            ledger: machine.repairLedger,
            areasWithRows: { PlaylistSyncCoverage.areasWithRows(playlistID: playlist.id, context: context) }
        ) else { return nil }
        return PlaylistSyncJob(
            playlistID: playlist.id,
            name: playlist.name,
            plan: PlaylistSyncPlan(sourceType: playlist.sourceType, repairingAreas: plan.repairingAreas, disabledAreas: disabledAreas),
            origin: .automatic,
            isFirstImport: playlist.lastSyncDate == nil,
            refreshesBrowsableAreas: plan.runsInBackground,
            repairedAreas: plan.repairedAreas
        )
    }

    // MARK: Viewer-requested syncs

    /// Sync Now (or Stalker's full-catalog download) for `playlist`, ahead of
    /// the automatic syncs waiting and behind whatever is already running.
    func sync(_ playlist: Playlist, full: Bool = false) {
        machine.enqueue(PlaylistSyncJob(
            playlistID: playlist.id,
            name: playlist.name,
            plan: PlaylistSyncPlan(sourceType: playlist.sourceType, full: full),
            origin: .manual,
            isFirstImport: playlist.lastSyncDate == nil
        ))
        startNextIfIdle()
    }

    /// Runs the last failed sync again.
    func retryRecent() {
        if machine.retryRecent() { startNextIfIdle() }
    }

    /// Stops the running sync. `ContentSyncManager` restores the playlist to
    /// idle and keeps what it had already imported; the next one then starts.
    func stop() {
        task?.cancel()
    }

    /// The viewer has seen how the last sync ended.
    func acknowledgeRecent() {
        machine.acknowledgeRecent()
    }

    /// A deleted playlist takes its waiting or running sync with it.
    func dropSyncs(notIn playlistIDs: Set<UUID>) {
        if machine.dropSyncs(notIn: playlistIDs) { stop() }
        reportBusy()
    }

    // MARK: Running

    private func startNextIfIdle() {
        defer { reportBusy() }
        guard task == nil, let job = machine.startNext() else { return }
        let playlistID = job.playlistID
        guard let playlist = try? container.mainContext.fetch(
            FetchDescriptor<Playlist>(predicate: #Predicate { $0.id == playlistID })
        ).first else {
            machine.finish(.stopped)
            startNextIfIdle()
            return
        }
        let progress = SyncProgress(steps: job.plan.steps)
        self.progress = progress
        let container = container
        let run = run
        Logger.database.info(
            "Sync \(job.isManual ? "requested" : "due", privacy: .public) for playlist \(playlistID): \(job.plan.syncAreas.map(\.rawValue).sorted(), privacy: .public)"
        )
        task = Task(priority: job.isAwaited ? .userInitiated : .utility) {
            let result: PlaylistSyncMachine.Result
            do {
                try await run(playlist, container, job.plan, progress)
                result = .succeeded
            } catch {
                // A cancelled request can surface as a URL error rather than
                // `CancellationError`; either way it was a stop, not a failure.
                result = Task.isCancelled || error is CancellationError ? .stopped : .failed(error.localizedDescription)
            }
            finished(job, result)
        }
    }

    private func finished(_ job: PlaylistSyncJob, _ result: PlaylistSyncMachine.Result) {
        task = nil
        if result == .succeeded, job.isManual {
            // The viewer has seen the areas this profile leaves out; don't
            // repair them behind their back.
            PlaylistSyncCoverage.deferAutomaticRepair(job.plan.skippedForProfile, playlistID: job.playlistID)
        }
        if result == .stopped { progress = nil }
        let reconnected = machine.finish(result)
        if let id = reconnected, let scope = automaticScope,
           let playlist = try? container.mainContext.fetch(FetchDescriptor<Playlist>(predicate: #Predicate { $0.id == id })).first
        {
            enqueueDue([playlist], activePlaylistID: scope.activePlaylistID, disabledAreas: scope.disabledAreas)
        }
        startNextIfIdle()
    }

    private func reportBusy() {
        guard machine.isBusy != reportedBusy else { return }
        reportedBusy = machine.isBusy
        busyChanged(reportedBusy)
    }
}
