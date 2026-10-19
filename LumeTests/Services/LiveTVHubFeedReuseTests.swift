import Foundation
@testable import Lume
import SwiftData
import Testing

/// A revisit to Live TV with nothing changed reuses the last completed hub
/// instead of rerunning discovery; tvOS rebuilds the tab, and so the feed,
/// on every visit. The title source stands in for discovery having run.
@MainActor
struct LiveTVHubFeedReuseTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private final class Calls {
        var count = 0
    }

    private func container() throws -> ModelContainer {
        try ModelContainer(for: LiveStream.self, EPGListing.self,
                           configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
    }

    /// A prefix of its own, so the process-wide reuse never crosses tests.
    private func key(prefix: String, hour: Int = 500_000, guideRevision: UInt64 = 1) -> LiveTVHubFeed.Key {
        LiveTVHubFeed.Key(prefix: prefix, visibility: "v", profile: "p", syncedAt: nil, guideRevision: guideRevision,
                          isActive: true, hour: hour, personalIDs: [])
    }

    private func load(_ feed: LiveTVHubFeed, _ key: LiveTVHubFeed.Key, in container: ModelContainer, calls: Calls) async {
        await feed.load(key: key, restriction: ContentRestriction(), container: container, now: now) {
            calls.count += 1
            return []
        }
    }

    @Test func `a new feed with an unchanged key reuses the completed hub`() async throws {
        let container = try container()
        let key = key(prefix: "\(UUID().uuidString)-")
        let calls = Calls()
        await load(LiveTVHubFeed(), key, in: container, calls: calls)
        await load(LiveTVHubFeed(), key, in: container, calls: calls)
        #expect(calls.count == 1)
        let reused = LiveTVHubFeed()
        await load(reused, key, in: container, calls: calls)
        #expect(!reused.isLoading)
        #expect(calls.count == 1)
    }

    @Test(arguments: ["hour", "guide"])
    func `any change to the key reloads`(_ change: String) async throws {
        let container = try container()
        let prefix = "\(UUID().uuidString)-"
        let calls = Calls()
        await load(LiveTVHubFeed(), key(prefix: prefix), in: container, calls: calls)
        let changed = change == "hour" ? key(prefix: prefix, hour: 500_001) : key(prefix: prefix, guideRevision: 2)
        await load(LiveTVHubFeed(), changed, in: container, calls: calls)
        #expect(calls.count == 2)
    }

    @Test func `a failed discovery is not reused`() async throws {
        let container = try container()
        let key = key(prefix: "\(UUID().uuidString)-")
        let calls = Calls()
        await LiveTVHubFeed().load(key: key, restriction: ContentRestriction(), container: container, now: now) {
            calls.count += 1
            throw URLError(.notConnectedToInternet)
        }
        await load(LiveTVHubFeed(), key, in: container, calls: calls)
        #expect(calls.count == 2)
    }
}
