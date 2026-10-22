import Foundation
@testable import Lume
import SwiftData
import Testing

/// A revisit to Live TV with nothing changed reuses the last completed hub
/// instead of rerunning discovery; tvOS rebuilds the tab, and so the feed,
/// on every visit. The title source stands in for discovery having run.
/// Serialized: the app keeps one completed hub, so concurrent tests would
/// replace each other's entry.
@MainActor
@Suite(.serialized)
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

    @Test func `hiding and unhiding a channel invalidates reuse without a guide or sync change`() async throws {
        let container = try container()
        let context = container.mainContext
        let prefix = "\(UUID().uuidString)-"
        let key = key(prefix: prefix)
        let calls = Calls()
        let stations = [("BBC One", "BBCOne.uk"), ("ITV1", "ITV1.uk"), ("Channel 4", "Channel4.uk")]
        for (index, station) in stations.enumerated() {
            let stream = LiveStream(id: "\(prefix)live-\(index)", streamId: index, name: station.0)
            stream.epgChannelId = station.1
            context.insert(stream)
        }
        try context.save()
        let stream = try #require(context.fetch(FetchDescriptor<LiveStream>()).first)
        let original = LiveTVHubFeed()
        await load(original, key, in: container, calls: calls)
        #expect(original.snapshot.collections.flatMap(\.channels).contains { $0.id == stream.id })
        stream.isHidden = true
        try context.save()

        let hidden = LiveTVHubFeed()
        await load(hidden, key, in: container, calls: calls)
        #expect(!hidden.snapshot.collections.flatMap(\.channels).contains { $0.id == stream.id })
        #expect(calls.count == 2)
        // The completed hidden snapshot remains reusable while unchanged.
        await load(LiveTVHubFeed(), key, in: container, calls: calls)
        #expect(calls.count == 2)

        stream.isHidden = false
        try context.save()
        let restored = LiveTVHubFeed()
        await load(restored, key, in: container, calls: calls)
        #expect(restored.snapshot.collections.flatMap(\.channels).contains { $0.id == stream.id })
        #expect(calls.count == 3)
    }
}
