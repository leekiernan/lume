import Foundation
@testable import Lume
import SwiftData
import Testing

/// The Xtream content phases follow the areas their run was planned with, not
/// whichever profile is active by the time a phase starts.
@Suite(.globalState)
struct XtreamPhaseAreaTests {
    @Test func `a phase planned for the run still runs after the active profile switches it off`() async throws {
        let container = try makeTestContainer()
        let host = "xtream-areas-\(UUID().uuidString.lowercased()).test"
        let playlist = Playlist(name: "Areas", serverURL: "http://\(host)", username: "u", password: "p")
        defer { XtreamDigestStore.removeAll(playlistId: playlist.id) }
        let context = ModelContext(container)
        context.insert(playlist)
        try context.save()
        StubURLProtocol.register(host: host, query: ("action", "get_vod_streams"), response: .init(body: "[{\"stream_id\":1,\"name\":\"Arrival\"}]"))
        StubURLProtocol.register(host: host, query: ("action", "get_series"), response: .init(body: "[{\"series_id\":1,\"name\":\"Harbor Lights\"}]"))

        // The profile active once the sync is under way has Series off.
        let key = AppAreaSettings.disabledAreasKey
        let previous = UserDefaults.standard.string(forKey: key)
        UserDefaults.standard.set("series", forKey: key)
        defer { UserDefaults.standard.set(previous, forKey: key) }

        let progress = await SyncProgress(steps: [.movies, .series])
        let manager = ContentSyncManager(modelContainer: container, xtreamClient: XtreamClient(urlSession: StubURLProtocol.makeSession()))
        let synced = try await manager.syncEnabledContent(for: playlist, playlistId: playlist.id, progress: progress, areas: [.movies, .series])

        #expect(synced == [.movies, .series])
        let check = ModelContext(container)
        #expect(try check.fetchCount(FetchDescriptor<Series>()) == 1)
        #expect(await progress.state(for: .series) == .completed)
    }
}
