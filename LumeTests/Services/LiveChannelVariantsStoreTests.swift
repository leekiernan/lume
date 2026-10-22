import Foundation
@testable import Lume
import SwiftData
import Testing

/// Grouping as the store sees it: what the lists show, what tuning plays, and
/// that a quality change is not a channel change.
@MainActor
struct LiveChannelVariantsStoreTests {
    private struct World {
        let container: ModelContainer
        let playlist: Playlist

        /// A fresh context, which reads what `reconcile` saved on its own.
        func context() -> ModelContext {
            ModelContext(container)
        }

        func stream(_ name: String, in context: ModelContext) throws -> LiveStream {
            try #require(try context.fetch(FetchDescriptor<LiveStream>(predicate: #Predicate { $0.name == name })).first)
        }
    }

    /// Sky Sports F1 in four qualities beside an ungrouped channel, all in one
    /// category, and grouped as an import leaves them.
    private func makeWorld(_ extra: [(name: String, category: String)] = []) throws -> World {
        let container = try makeTestContainer()
        let context = ModelContext(container)
        let playlist = Playlist(name: "Test", serverURL: "http://example.com:8080", username: "user", password: "pass")
        context.insert(playlist)
        let channels = [
            ("Sky Sports F1 UHD", "sports"), ("Sky Sports F1 FHD 50FPS", "sports"), ("Sky Sports F1 FHD", "sports"),
            ("Sky Sports F1 HD", "sports"), ("Sky Sports Golf HD", "sports")
        ] + extra.map { ($0.name, $0.category) }
        for (offset, channel) in channels.enumerated() {
            let streamId = 100 + offset
            context.insert(LiveStream(
                id: "\(playlist.id.uuidString)-live-\(streamId)", streamId: streamId, name: channel.0,
                num: offset + 1, categoryId: channel.1
            ))
        }
        try context.save()
        LiveChannelVariants.reconcile(playlistID: playlist.id, container: container)
        return World(container: container, playlist: playlist)
    }

    private func defaults() throws -> UserDefaults {
        try #require(UserDefaults(suiteName: "LiveChannelVariantsStoreTests-\(UUID().uuidString)"))
    }

    @Test func `the category list shows one row per channel`() throws {
        let world = try makeWorld()
        let rows = try world.context().fetch(LiveChannelQuery.descriptor(for: .category("sports"), sort: .playlist))
        #expect(rows.map(\.displayName) == ["Sky Sports F1", "Sky Sports Golf HD"])
        #expect(rows.first?.variantQualities == "UHD · FHD · HD")
    }

    @Test func `tuning opens the best fit for the screen, anchored to the row`() throws {
        let world = try makeWorld()
        let context = world.context()
        let row = try world.stream("Sky Sports F1 UHD", in: context)
        let media = try #require(PlayableMedia.from(stream: row, playlist: world.playlist))
        #expect(media.title == "Sky Sports F1 FHD 50FPS")
        #expect(media.channelRowID == row.id)
    }

    @Test func `the quality watched last is the one a channel opens in`() throws {
        let world = try makeWorld()
        let context = world.context()
        try world.stream("Sky Sports F1 HD", in: context).lastWatchedDate = .now
        try world.stream("Sky Sports F1 UHD", in: context).lastWatchedDate = .now.addingTimeInterval(-60)
        let row = try world.stream("Sky Sports F1 UHD", in: context)
        #expect(PlayableMedia.from(stream: row, playlist: world.playlist)?.title == "Sky Sports F1 HD")
    }

    @Test func `a quality in a hidden or restricted category is never tuned to`() throws {
        let world = try makeWorld([("Sky Sports F1 SD", "locked")])
        let context = world.context()
        let locked = Category(apiId: "locked", name: "Locked", parentId: 0, typeRaw: CategoryType.live.rawValue)
        locked.isRestricted = true
        context.insert(locked)
        let watched = try world.stream("Sky Sports F1 SD", in: context)
        watched.categoryId = locked.id
        watched.lastWatchedDate = .now
        try context.save()
        let row = try world.stream("Sky Sports F1 UHD", in: context)
        #expect(PlayableMedia.from(stream: row, playlist: world.playlist)?.title == "Sky Sports F1 FHD 50FPS")
    }

    @Test func `the Source menu offers the other qualities, anchored to the row`() throws {
        let world = try makeWorld()
        let context = world.context()
        let row = try world.stream("Sky Sports F1 UHD", in: context)
        let playing = try #require(PlayableMedia.from(stream: row, playlist: world.playlist))
        let sources = try #require(PlayerSourceSwitch.sources(for: playing, restriction: ContentRestriction(), in: context))
        #expect(sources.current.title == "FHD 50FPS")
        #expect(sources.alternatives.map(\.source.title) == ["FHD", "HD", "UHD"])
        #expect(sources.alternatives.allSatisfy { $0.media.channelRowID == row.id })
        #expect(sources.alternatives.allSatisfy(\.media.isLive))
    }

    @Test func `changing quality leaves recall on the channel before`() throws {
        let world = try makeWorld()
        let context = world.context()
        let store = try defaults()
        let golf = try #require(PlayableMedia.from(stream: world.stream("Sky Sports Golf HD", in: context), playlist: world.playlist))
        let formula = try #require(PlayableMedia.from(stream: world.stream("Sky Sports F1 UHD", in: context), playlist: world.playlist))
        LiveChannelHistory.record(golf, profileID: nil, defaults: store)
        LiveChannelHistory.record(formula, profileID: nil, defaults: store)
        let sources = try #require(PlayerSourceSwitch.sources(for: formula, restriction: ContentRestriction(), in: context))
        try LiveChannelHistory.record(#require(sources.alternatives.first).media, profileID: nil, defaults: store)

        let recall = LiveChannelHistory.recallMedia(in: context, restriction: ContentRestriction(), profileID: nil, defaults: store)
        #expect(recall?.title == "Sky Sports Golf HD")
    }

    @Test func `the Recently Watched list shows a channel once, as the quality watched last`() throws {
        let world = try makeWorld()
        let context = world.context()
        try world.stream("Sky Sports F1 HD", in: context).lastWatchedDate = .now
        try world.stream("Sky Sports F1 UHD", in: context).lastWatchedDate = .now.addingTimeInterval(-60)
        try world.stream("Sky Sports Golf HD", in: context).lastWatchedDate = .now.addingTimeInterval(-120)
        try context.save()
        let rows = try LiveChannelQuery.scoped(
            context.fetch(LiveChannelQuery.descriptor(for: .recentlyWatched, sort: .playlist)),
            scope: .recentlyWatched, playlistPrefix: world.playlist.contentIDPrefix, restriction: ContentRestriction()
        )
        #expect(rows.map(\.name) == ["Sky Sports F1 HD", "Sky Sports Golf HD"])
    }

    @Test func `stepping down goes one quality at a time and keeps the pick`() throws {
        let world = try makeWorld()
        let context = world.context()
        let all = try ["Sky Sports F1 UHD", "Sky Sports F1 FHD 50FPS", "Sky Sports F1 FHD", "Sky Sports F1 HD"]
            .map { try world.stream($0, in: context) }
        func below(_ name: String) throws -> String? {
            let current = try world.stream(name, in: context)
            return LiveChannelVariants.stepDown(from: current, among: all.filter { $0.id != current.id })?.name
        }
        #expect(try below("Sky Sports F1 UHD") == "Sky Sports F1 FHD 50FPS")
        #expect(try below("Sky Sports F1 FHD 50FPS") == "Sky Sports F1 FHD")
        #expect(try below("Sky Sports F1 FHD") == "Sky Sports F1 HD")
        #expect(try below("Sky Sports F1 HD") == nil)

        let fhd = try #require(PlayableMedia.from(stream: all[2], playlist: world.playlist, choosingQuality: false))
        let stepped = fhd.asQuality(anchoredAt: all[0].id, pickID: all[1].id)
        #expect(stepped.progressRef == .live(all[1].id))
        #expect(stepped.channelRowID == all[0].id)
        #expect(fhd.asQuality(anchoredAt: all[0].id).progressRef == .live(all[2].id))
    }

    @Test func `regrouping clears a channel that lost its other qualities`() throws {
        let world = try makeWorld()
        let context = world.context()
        for name in ["Sky Sports F1 UHD", "Sky Sports F1 FHD 50FPS", "Sky Sports F1 FHD"] {
            try context.delete(world.stream(name, in: context))
        }
        try context.save()
        LiveChannelVariants.reconcile(playlistID: world.playlist.id, container: world.container)
        let remaining = try world.stream("Sky Sports F1 HD", in: world.context())
        #expect(remaining.variantKey == nil)
        #expect(!remaining.isVariantFollower)
        #expect(remaining.displayName == "Sky Sports F1 HD")
    }
}
