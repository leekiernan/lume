import Foundation
@testable import Lume
import SwiftData
import Testing

/// Stands in for `PlaylistSyncRun.perform`: each sync parks until the test
/// ends it.
@MainActor
private final class SyncRunnerStub {
    struct Failure: LocalizedError {
        var errorDescription: String? {
            "The server went away."
        }
    }

    private(set) var started: [UUID] = []
    private(set) var progresses: [UUID: SyncProgress] = [:]
    private var waiters: [UUID: CheckedContinuation<Void, Error>] = [:]

    func run(_ playlist: Playlist, progress: SyncProgress) async throws {
        let id = playlist.id
        started.append(id)
        progresses[id] = progress
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { waiters[id] = $0 }
        } onCancel: {
            Task { @MainActor in self.end(id, throwing: CancellationError()) }
        }
    }

    func isRunning(_ id: UUID) -> Bool {
        waiters[id] != nil
    }

    func end(_ id: UUID, throwing error: Error? = nil) {
        guard let waiter = waiters.removeValue(forKey: id) else { return }
        if let error { waiter.resume(throwing: error) } else { waiter.resume() }
    }
}

/// Reads the active profile's Library areas through each job's plan.
@Suite(.readsGlobalState)
@MainActor
struct PlaylistSyncCenterTests {
    @Test func `a reconnection during sync retries a later failure using the current profile plan`() async throws {
        let playlist = try makePlaylist("a")
        let active = playlist.id.uuidString
        center.enqueueDue([playlist], activePlaylistID: active, disabledAreasRaw: "")
        await settle { stub.isRunning(playlist.id) }
        playlist.password = "replacement"
        center.reconnected([playlist.id], playlists: [playlist], activePlaylistID: active, disabledAreasRaw: "")
        center.enqueueDue([playlist], activePlaylistID: active, disabledAreasRaw: "series")
        stub.end(playlist.id, throwing: SyncRunnerStub.Failure())
        await settle { stub.started.count == 2 }
        #expect(stub.started == [playlist.id, playlist.id])
        #expect(center.running?.plan.syncAreas.contains(.series) == false)
        await finish(playlist)
    }

    private let container: ModelContainer
    private let stub = SyncRunnerStub()
    private let center: PlaylistSyncCenter
    private let busy: BusyLog

    @MainActor
    final class BusyLog {
        var changes: [Bool] = []
    }

    init() throws {
        container = try makeTestContainer()
        let stub = stub
        let busy = BusyLog()
        self.busy = busy
        center = PlaylistSyncCenter(
            container: container,
            runsAutomaticSyncs: true,
            busyChanged: { busy.changes.append($0) },
            run: { playlist, _, _, progress in try await stub.run(playlist, progress: progress) }
        )
    }

    private func makePlaylist(_ name: String, synced: Bool = false) throws -> Playlist {
        let playlist = Playlist(name: name, serverURL: "http://\(name).example.com", username: "u", password: "p")
        if synced { playlist.lastSyncDate = Date().addingTimeInterval(-30 * 24 * 60 * 60) }
        container.mainContext.insert(playlist)
        try container.mainContext.save()
        return playlist
    }

    /// The center hops through its own task between states.
    private func settle(_ condition: () -> Bool) async {
        for _ in 0 ..< 2000 where !condition() {
            await Task.yield()
        }
    }

    private func finish(_ playlist: Playlist, throwing error: Error? = nil) async {
        await settle { stub.isRunning(playlist.id) }
        stub.end(playlist.id, throwing: error)
        await settle { center.running?.playlistID != playlist.id }
    }

    @Test func `syncs run one at a time in the order asked for, reporting busy to the guide`() async throws {
        let first = try makePlaylist("a"), second = try makePlaylist("b")
        center.sync(first)
        center.sync(second)

        #expect(center.running?.playlistID == first.id)
        #expect(center.upNext.map(\.playlistID) == [second.id])
        #expect(busy.changes == [true])

        await finish(first)
        #expect(center.running?.playlistID == second.id)
        await finish(second)
        #expect(!center.isBusy)
        #expect(busy.changes == [true, false])
        #expect(stub.started == [first.id, second.id])
    }

    @Test func `a manual sync goes ahead of the automatic ones waiting`() throws {
        let running = try makePlaylist("a"), automatic = try makePlaylist("b"), manual = try makePlaylist("c")
        center.sync(running)
        center.enqueueDue([automatic], activePlaylistID: automatic.id.uuidString, disabledAreasRaw: "")
        center.sync(manual)

        #expect(center.upNext.map(\.playlistID) == [manual.id, automatic.id])
        #expect(center.upNext.map(\.isManual) == [true, false])
    }

    @Test func `an automatic sync is queued once a session, and not for a playlist off screen`() throws {
        let active = try makePlaylist("a"), other = try makePlaylist("b", synced: true)
        let blocker = try makePlaylist("c")
        center.sync(blocker)
        center.enqueueDue([active, other], activePlaylistID: active.id.uuidString, disabledAreasRaw: "")
        center.enqueueDue([active, other], activePlaylistID: active.id.uuidString, disabledAreasRaw: "")

        #expect(center.upNext.map(\.playlistID) == [active.id])
        #expect(center.upNext.first?.isFirstImport == true)
    }

    @Test func `automatic syncs stay off where the host asks`() throws {
        let quiet = PlaylistSyncCenter(container: container, runsAutomaticSyncs: false, busyChanged: { _ in }, run: { _, _, _, _ in })
        let playlist = try makePlaylist("a")
        quiet.enqueueDue([playlist], activePlaylistID: playlist.id.uuidString, disabledAreasRaw: "")

        #expect(!quiet.isBusy)
    }

    @Test func `a failure is reported for its own playlist and can be retried`() async throws {
        let playlist = try makePlaylist("a"), other = try makePlaylist("b")
        center.sync(playlist)
        await finish(playlist, throwing: SyncRunnerStub.Failure())

        #expect(center.recentFailure()?.failure == "The server went away.")
        #expect(center.recentFailure(for: playlist.id) != nil)
        #expect(center.recentFailure(for: other.id) == nil)

        center.retryRecent()
        #expect(center.running?.playlistID == playlist.id)
        await finish(playlist)
        #expect(stub.started == [playlist.id, playlist.id])
        #expect(center.recent?.failed == false)
    }

    @Test func `stopping a sync leaves no result and moves on`() async throws {
        let stopped = try makePlaylist("a"), next = try makePlaylist("b")
        center.sync(stopped)
        center.sync(next)
        await settle { stub.isRunning(stopped.id) }

        center.stop()
        await settle { center.running?.playlistID == next.id }

        #expect(center.running?.playlistID == next.id)
        #expect(center.recent == nil)
    }

    @Test func `a deleted playlist takes its syncs with it`() async throws {
        let kept = try makePlaylist("a"), running = try makePlaylist("b"), waiting = try makePlaylist("c")
        center.sync(running)
        center.sync(waiting)
        center.sync(kept)
        await settle { stub.isRunning(running.id) }

        center.dropSyncs(notIn: [kept.id])
        await settle { center.running?.playlistID == kept.id }

        #expect(center.running?.playlistID == kept.id)
        #expect(center.upNext.isEmpty)
        #expect(!stub.started.contains(waiting.id))
    }

    @Test func `a tab waits for its step only during a first import of its own playlist`() async throws {
        let fresh = try makePlaylist("a")
        center.sync(fresh)
        await settle { stub.isRunning(fresh.id) }
        let progress = try #require(stub.progresses[fresh.id])

        #expect(center.isFirstImportAwaiting(.movies, playlistID: fresh.id))
        #expect(!center.isFirstImportAwaiting(.playlistImport, playlistID: fresh.id), "not an Xtream step")
        #expect(!center.isFirstImportAwaiting(.movies, playlistID: UUID()))

        progress.start(.movies)
        progress.update(detail: "10 of 10")
        progress.complete(.movies)
        #expect(!center.isFirstImportAwaiting(.movies, playlistID: fresh.id))
        #expect(center.isFirstImportAwaiting(.series, playlistID: fresh.id))
        #expect(progress.detail(for: .movies) == "10 of 10")
    }

    @Test func `a refresh never hides the rows already there`() throws {
        let synced = try makePlaylist("a", synced: true)
        center.sync(synced)

        #expect(!center.isFirstImportAwaiting(.movies, playlistID: synced.id))
    }

    @Test func `a reconnection re-plans a playlist whose sync failed, and only that one`() async throws {
        let failed = try makePlaylist("a"), healthy = try makePlaylist("b", synced: true)
        let active = failed.id.uuidString
        center.enqueueDue([failed], activePlaylistID: active, disabledAreasRaw: "")
        await finish(failed, throwing: SyncRunnerStub.Failure())
        #expect(!center.isBusy)

        center.reconnected([healthy.id], playlists: [failed, healthy], activePlaylistID: active, disabledAreasRaw: "")
        #expect(!center.isBusy, "new details for a playlist that didn't fail change nothing")

        center.reconnected([failed.id, healthy.id], playlists: [failed, healthy], activePlaylistID: active, disabledAreasRaw: "")
        #expect(center.running?.playlistID == failed.id)
        #expect(center.upNext.isEmpty)
        #expect(center.recent == nil, "the old failure is cleared for the new attempt")
    }
}
