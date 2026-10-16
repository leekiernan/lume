import Foundation
@testable import Lume
import Testing

@MainActor
struct SportsCacheIOTests {
    @Test func `queued writes retain the latest snapshot and hydrate asynchronously`() async {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let disk = SportsCacheStore(directory: directory)
        let store = SportsStore(cache: disk)
        for timestamp in 1 ... 30 {
            store.update(SportsLeagueSnapshot(fetchedAt: Date(timeIntervalSince1970: Double(timestamp))), for: "league")
        }
        await store.flushCache()
        let reopened = SportsStore(cache: disk)
        await reopened.hydrate(leagueIds: ["league", "league"])
        #expect(reopened.snapshot(for: "league")?.fetchedAt == Date(timeIntervalSince1970: 30))
    }
}
