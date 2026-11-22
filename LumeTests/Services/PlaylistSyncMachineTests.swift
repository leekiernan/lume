import Foundation
@testable import Lume
import Testing

@MainActor
struct PlaylistSyncMachineTests {
    @Test func `reconnection during a running failure releases its attempt once for fresh planning`() {
        var machine = PlaylistSyncMachine()
        let running = job(.automatic, repaired: [.movies])
        machine.enqueue(running)
        _ = machine.startNext()
        #expect(machine.reconnected([running.playlistID], failedIDs: []).isEmpty)
        #expect(machine.finish(.failed("old connection")) == running.playlistID)
        #expect(!machine.wasAttempted(running.playlistID))
        #expect(machine.repairLedger.untried([.movies], for: running.playlistID) == [.movies])
        machine.enqueue(running)
        _ = machine.startNext()
        #expect(machine.finish(.failed("new connection")) == nil)
    }

    @Test func `reconnection does not repeat a success or override a stop`() {
        for result in [PlaylistSyncMachine.Result.succeeded, .stopped] {
            var machine = PlaylistSyncMachine()
            let running = job(.automatic)
            machine.enqueue(running)
            _ = machine.startNext()
            _ = machine.reconnected([running.playlistID], failedIDs: [])
            #expect(machine.finish(result) == nil)
            #expect(machine.pending.isEmpty)
        }
    }

    private func job(_ origin: PlaylistSyncJob.Origin, id: UUID = UUID(), firstImport: Bool = false,
                     repairing: Set<AppArea>? = nil, browsable: Bool = false, repaired: Set<AppArea> = []) -> PlaylistSyncJob
    {
        PlaylistSyncJob(
            playlistID: id, name: "P", plan: PlaylistSyncPlan(sourceType: .xtream, repairingAreas: repairing, enabledAreas: [.movies, .series, .liveTV]),
            origin: origin, isFirstImport: firstImport, refreshesBrowsableAreas: browsable, repairedAreas: repaired
        )
    }

    @Test func `jobs start one at a time in the order they were queued`() {
        var machine = PlaylistSyncMachine()
        let first = job(.automatic), second = job(.automatic)
        machine.enqueue(first)
        machine.enqueue(second)

        let started = machine.startNext()
        let whileRunning = machine.startNext()
        machine.finish(.succeeded)
        let next = machine.startNext()
        #expect(started == first)
        #expect(whileRunning == nil)
        #expect(next == second)
    }

    @Test func `a manual job goes ahead of automatic ones but behind earlier manual ones`() {
        var machine = PlaylistSyncMachine()
        let automatic = job(.automatic), firstManual = job(.manual), secondManual = job(.manual)
        machine.enqueue(automatic)
        machine.enqueue(firstManual)
        machine.enqueue(secondManual)

        #expect(machine.pending.map(\.id) == [firstManual.id, secondManual.id, automatic.id])
    }

    @Test func `asking for a playlist waiting automatically moves it up rather than queueing it twice`() {
        var machine = PlaylistSyncMachine()
        let id = UUID()
        let other = job(.automatic)
        machine.enqueue(other)
        machine.enqueue(job(.automatic, id: id))

        let movedUp = machine.enqueue(job(.manual, id: id))
        #expect(movedUp)
        #expect(machine.pending.map(\.id) == [id, other.id])
        #expect(machine.pending.first?.isManual == true)
        let askedAgain = machine.enqueue(job(.manual, id: id))
        let dueAgain = machine.enqueue(job(.automatic, id: id))
        #expect(!askedAgain)
        #expect(!dueAgain)
        #expect(machine.pending.count == 2)
    }

    @Test func `a playlist already running is not queued again`() {
        var machine = PlaylistSyncMachine()
        let running = job(.manual)
        machine.enqueue(running)
        _ = machine.startNext()

        let queued = machine.enqueue(job(.manual, id: running.playlistID))
        #expect(!queued)
        #expect(machine.pending.isEmpty)
    }

    @Test func `outcomes are kept until seen, and a stop leaves none`() {
        var machine = PlaylistSyncMachine()
        let succeeded = job(.manual), stopped = job(.manual)
        machine.enqueue(succeeded)
        _ = machine.startNext()
        machine.finish(.succeeded)
        #expect(machine.recent?.job == succeeded)
        #expect(machine.recent?.failed == false)

        machine.enqueue(stopped)
        _ = machine.startNext()
        machine.acknowledgeRecent()
        #expect(machine.recent != nil, "nothing is acknowledged while a sync runs")
        machine.finish(.stopped)
        #expect(machine.recent?.job == succeeded, "a stop doesn't erase another playlist's result")

        machine.acknowledgeRecent()
        #expect(machine.recent == nil)
    }

    @Test func `a failure is reported for its playlist and retried as a manual job`() {
        var machine = PlaylistSyncMachine()
        let failing = job(.automatic, firstImport: true)
        machine.enqueue(failing)
        _ = machine.startNext()
        machine.finish(.failed("The server went away."))

        #expect(machine.recentFailure()?.failure == "The server went away.")
        #expect(machine.recentFailure(in: [failing.playlistID]) != nil)
        #expect(machine.recentFailure(in: [UUID()]) == nil)

        let retried = machine.retryRecent()
        #expect(retried)
        #expect(machine.recent == nil)
        #expect(machine.pending.first?.isManual == true)
        #expect(machine.pending.first?.isFirstImport == true)
        let retriedAgain = machine.retryRecent()
        #expect(!retriedAgain)
    }

    @Test func `dropping deleted playlists clears their jobs and flags the running one`() {
        var machine = PlaylistSyncMachine()
        let running = job(.manual), waiting = job(.automatic), kept = job(.automatic)
        machine.enqueue(running)
        machine.enqueue(waiting)
        machine.enqueue(kept)
        _ = machine.startNext()

        let runningDropped = machine.dropSyncs(notIn: [kept.playlistID])
        #expect(runningDropped)
        #expect(machine.pending.map(\.id) == [kept.id])
        let keptRunning = machine.dropSyncs(notIn: [kept.playlistID, running.playlistID])
        #expect(!keptRunning)
    }

    @Test func `automatic jobs record the session attempt and their repairs`() {
        var machine = PlaylistSyncMachine()
        let repair = job(.automatic, repairing: [.liveTV], repaired: [.liveTV])
        machine.enqueue(repair)
        machine.enqueue(job(.manual))

        #expect(machine.wasAttempted(repair.playlistID))
        #expect(machine.repairLedger.untried([.liveTV], for: repair.playlistID).isEmpty)
        #expect(machine.attempted.count == 1, "a manual sync isn't an automatic attempt")
    }

    @Test func `only work someone waits on runs at user-initiated priority`() {
        #expect(job(.manual).isAwaited)
        #expect(job(.automatic, firstImport: true).isAwaited)
        #expect(job(.automatic, repairing: [.liveTV], browsable: false).isAwaited)
        #expect(!job(.automatic, repairing: [.liveTV], browsable: true).isAwaited)
        #expect(!job(.automatic).isAwaited, "a regular refresh of a synced playlist gives way to browsing")
    }

    @Test func `reconnection resets failed attempts but re-plans only those not queued`() {
        var machine = PlaylistSyncMachine()
        let retry = job(.automatic, repaired: [.movies, .liveTV])
        let queued = job(.automatic, repaired: [.movies])
        let healthy = job(.automatic, repaired: [.movies])
        for each in [retry, queued, healthy] {
            machine.enqueue(each)
        }
        // Retry has run and failed; queued and healthy are still waiting.
        _ = machine.startNext()
        machine.finish(.failed("x"))
        machine.acknowledgeRecent()
        let pendingQueued = machine.pending.first { $0.playlistID == queued.playlistID }
        #expect(pendingQueued != nil)

        let replan = machine.reconnected(
            [retry.playlistID, queued.playlistID, healthy.playlistID],
            failedIDs: [retry.playlistID, queued.playlistID]
        )

        #expect(replan == [retry.playlistID])
        #expect(!machine.wasAttempted(retry.playlistID))
        #expect(!machine.wasAttempted(queued.playlistID))
        #expect(machine.wasAttempted(healthy.playlistID))
        #expect(machine.repairLedger.untried([.movies, .liveTV], for: retry.playlistID) == [.movies, .liveTV])
        #expect(machine.repairLedger.untried([.movies], for: healthy.playlistID).isEmpty)
        let nothing = machine.reconnected([], failedIDs: [retry.playlistID])
        #expect(nothing.isEmpty)
    }

    @Test func `the last failure counts as failed for a reconnection even before the playlist row says so`() {
        var machine = PlaylistSyncMachine()
        let failing = job(.automatic)
        machine.enqueue(failing)
        _ = machine.startNext()
        machine.finish(.failed("x"))

        let replan = machine.reconnected([failing.playlistID], failedIDs: [])
        #expect(replan == [failing.playlistID])
        #expect(machine.recent == nil)
    }
}
