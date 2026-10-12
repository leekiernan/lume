import Foundation
@testable import Lume
import SwiftData
import Testing

@MainActor
@Suite(.readsGlobalState)
struct SportsProxyResolverTests {
    private func setup(body: String? = nil, helpers: LumeSportsClientTests? = nil) throws -> (ModelContainer, Playlist, LumeSportsClient, LumeSportsClientTests, String) {
        let helpers = helpers ?? LumeSportsClientTests()
        let (client, source, host) = try helpers.client(body: body ?? helpers.body())
        let container = try makeTestContainer()
        let context = container.mainContext
        let playlist = Playlist(name: "Proxy", serverURL: "https://\(host)/panel?token=one%26two", username: "u&one", password: "p?two")
        // Use the same source identity, including the playlist UUID.
        playlist.id = source.playlistID
        context.insert(playlist)
        context.insert(stream(playlist, id: 123, name: "Sky Sports", epg: "sky.uk"))
        try context.save()
        return (container, playlist, client, helpers, host)
    }

    private func stream(_ playlist: Playlist, id: Int, name: String, epg: String) -> LiveStream {
        LiveStream(id: CatalogID.content(playlist.id, kind: .live, key: id), streamId: id, name: name,
                   epgChannelId: epg, categoryId: CatalogID.category(playlist.id, type: "live", key: "7"))
    }

    private func listing(epg: String, kickoff: Date) -> EPGListing {
        EPGListing(id: UUID().uuidString, channelId: epg, title: "Arsenal v Leeds United", listingDescription: "",
                   start: kickoff, end: kickoff.addingTimeInterval(7200))
    }

    @Test func `proxy supplies a match without a local guide and cannot leak evidence text`() async throws {
        let (container, playlist, client, helpers, _) = try setup()
        let game = helpers.fixture()
        let result = await SportsChannelResolver.resolve(container: container, fixtures: [game], proxyClient: client)
        let channel = try #require(result[game.id]?.first)
        #expect(channel.playlistID == playlist.id)
        #expect(channel.source == .epgTitleSubtitle)
        #expect(channel.isConfident)
        #expect(channel.matchedTitle == nil)
    }

    @Test func `same provider ID in another playlist does not receive proxy evidence`() async throws {
        let (container, playlist, client, helpers, _) = try setup()
        let other = Playlist(name: "Ordinary", serverURL: "", username: "", password: "")
        container.mainContext.insert(other)
        container.mainContext.insert(stream(other, id: 123, name: "Sky Sports", epg: "sky.uk"))
        try container.mainContext.save()
        let result = await SportsChannelResolver.resolve(container: container, fixtures: [helpers.fixture()], proxyClient: client)
        #expect(result["401"]?.map(\.playlistID) == [playlist.id])
    }

    @Test func `hidden and restricted proxy candidates cannot authorize channels`() async throws {
        let (container, playlist, client, helpers, _) = try setup()
        let context = container.mainContext
        let streams = try context.fetch(FetchDescriptor<LiveStream>())
        let hidden = try #require(streams.first)
        hidden.isHidden = true
        try context.save()
        #expect(await SportsChannelResolver.resolve(container: container, fixtures: [helpers.fixture()], proxyClient: client)["401"] == nil)
        hidden.isHidden = false
        try context.save()
        let category = CatalogID.category(playlist.id, type: "live", key: "7")
        let restriction = ContentRestriction(isActive: true, restrictedCategoryIDs: [category])
        let result = await SportsChannelResolver.resolve(container: container, fixtures: [helpers.fixture()], restriction: restriction, proxyClient: client)
        #expect(result["401"] == nil)
    }

    @Test(arguments: ["empty", "truncated", "stale", "unknown", "renamed", "badEvidence"])
    func `unusable proxy data preserves existing guide matching`(_ reason: String) async throws {
        let helpers = LumeSportsClientTests()
        var item = helpers.item()
        var changes: [String: Any] = [:]
        switch reason {
        case "empty": item["candidates"] = []
        case "truncated": item["truncated"] = true
        case "stale": changes["expires_at"] = helpers.date(helpers.now.addingTimeInterval(-1))
        case "unknown": item["candidates"] = [helpers.candidate(streamID: 999)]
        case "renamed":
            var candidate = helpers.candidate()
            candidate["name"] = "Old channel name"
            item["candidates"] = [candidate]
        default: item["candidates"] = [helpers.candidate(strength: "invented")]
        }
        let (container, _, client, _, _) = try setup(body: helpers.body(items: [item], changes: changes), helpers: helpers)
        let game = helpers.fixture()
        container.mainContext.insert(listing(epg: "sky.uk", kickoff: game.startDate))
        try container.mainContext.save()
        let result = await SportsChannelResolver.resolve(container: container, fixtures: [game], proxyClient: client)
        #expect(result[game.id]?.first?.matchedTitle == "Arsenal v Leeds United")
    }

    @Test func `another playlist still resolves locally and confidence is recomputed across both`() async throws {
        let (container, _, client, helpers, _) = try setup()
        let other = Playlist(name: "Other", serverURL: "", username: "", password: "")
        container.mainContext.insert(other)
        container.mainContext.insert(stream(other, id: 456, name: "Other Sports", epg: "other.uk"))
        container.mainContext.insert(listing(epg: "other.uk", kickoff: helpers.now))
        try container.mainContext.save()
        let result = await SportsChannelResolver.resolve(container: container, fixtures: [helpers.fixture()], proxyClient: client)
        #expect(result["401"]?.count == 2)
        #expect(result["401"]?.allSatisfy { !$0.isConfident } == true)
    }

    /// A proxy-only channel-name suggestion is never one-tap; the same channel
    /// found by the local matcher keeps the confidence it has without a proxy.
    @Test(arguments: [false, true])
    func `untimed evidence never authorizes automatic playback alone`(_ namedForFixture: Bool) async throws {
        let helpers = LumeSportsClientTests()
        var candidate = helpers.candidate()
        if namedForFixture { candidate["name"] = "Arsenal v Leeds United" }
        candidate["evidence"] = ["source": "provider_channel", "field": "name", "text": "Arsenal v Leeds United",
                                 "strength": "untimed_channel_pairing", "classification": "unknown"]
        let (container, _, client, _, _) = try setup(body: helpers.body(items: [helpers.item(candidates: [candidate])]), helpers: helpers)
        if namedForFixture {
            let streams = try container.mainContext.fetch(FetchDescriptor<LiveStream>())
            let stream = try #require(streams.first)
            stream.name = "Arsenal v Leeds United"
            try container.mainContext.save()
        }
        let result = await SportsChannelResolver.resolve(container: container, fixtures: [helpers.fixture()], proxyClient: client)
        #expect(result["401"]?.first?.source == .channelName)
        #expect(result["401"]?.first?.isConfident == namedForFixture)
    }

    @Test func `remembered pick remains above proxy matching`() async throws {
        let (container, playlist, client, helpers, _) = try setup()
        container.mainContext.insert(stream(playlist, id: 456, name: "My favourite", epg: "favorite.uk"))
        try container.mainContext.save()
        let defaults = try #require(UserDefaults(suiteName: UUID().uuidString))
        let picks = SportsChannelPicks(defaults: defaults)
        picks.remember(competitionKey: "espn:soccer/eng.1", channelKey: "favorite.uk", playlistID: playlist.id)
        let result = await SportsChannelResolver.resolve(container: container, fixtures: [helpers.fixture()], picks: picks, proxyClient: client)
        #expect(result["401"]?.first?.source == .userPick)
        #expect(result["401"]?.first?.stream.name == "My favourite")
    }

    /// The proxy has no aliases, so a playlist it answers for still runs the
    /// local matcher: "Man Utd v Spurs"-style guide lines only it can read.
    @Test func `a playlist the proxy answers still gets the local matches it missed`() async throws {
        let (container, playlist, client, helpers, _) = try setup()
        container.mainContext.insert(stream(playlist, id: 456, name: "Other channel", epg: "other.uk"))
        container.mainContext.insert(listing(epg: "other.uk", kickoff: helpers.now))
        try container.mainContext.save()
        let result = await SportsChannelResolver.resolve(container: container, fixtures: [helpers.fixture()], proxyClient: client)
        let ids = Set(result["401"]?.map(\.stream.id) ?? [])
        #expect(ids == Set([123, 456].map { CatalogID.content(playlist.id, kind: .live, key: $0) }))
        #expect(result["401"]?.allSatisfy { !$0.isConfident } == true)
    }

    @Test(arguments: [false, true])
    func `provider headline evidence ranks above a supplement's`(_ overlappingGuide: Bool) async throws {
        let helpers = LumeSportsClientTests()
        var provider = helpers.candidate(streamID: 456)
        provider["epg_id"] = "provider.uk"
        provider["name"] = "Provider Sports"
        var evidence = try #require(provider["evidence"] as? [String: Any])
        evidence["source"] = "provider"
        provider["evidence"] = evidence
        let body = try helpers.body(items: [helpers.item(candidates: [helpers.candidate(), provider])])
        let (container, playlist, client, _, _) = try setup(body: body, helpers: helpers)
        container.mainContext.insert(stream(playlist, id: 456, name: "Provider Sports", epg: "provider.uk"))
        if overlappingGuide {
            // The merged guide supplies the supplement as a subtitle (score 6),
            // while the provider's own title scores 4. Field weight must not
            // reverse the separately verified evidence provenance priority.
            let supplement = listing(epg: "sky.uk", kickoff: helpers.now)
            supplement.title = "Live football"
            supplement.subtitle = "Arsenal v Leeds United"
            container.mainContext.insert(supplement)
            container.mainContext.insert(listing(epg: "provider.uk", kickoff: helpers.now))
        }
        try container.mainContext.save()
        let result = await SportsChannelResolver.resolve(container: container, fixtures: [helpers.fixture()], proxyClient: client)
        #expect(result["401"]?.map(\.stream.name) == ["Provider Sports", "Sky Sports"])
        #expect(result["401"]?.allSatisfy { !$0.isConfident } == true)
    }

    /// The proxy's supplement evidence covers one programme. A local headline
    /// hit on a different programme of that channel is independent evidence,
    /// so the supplement priority doesn't demote it below the provider's.
    @Test func `a local headline on another programme keeps its ordinary priority`() async throws {
        let helpers = LumeSportsClientTests()
        var provider = helpers.candidate(streamID: 456)
        provider["epg_id"] = "provider.uk"
        provider["name"] = "Provider Sports"
        var evidence = try #require(provider["evidence"] as? [String: Any])
        evidence["source"] = "provider"
        provider["evidence"] = evidence
        let body = try helpers.body(items: [helpers.item(candidates: [helpers.candidate(), provider])])
        let (container, playlist, client, _, _) = try setup(body: body, helpers: helpers)
        container.mainContext.insert(stream(playlist, id: 456, name: "Provider Sports", epg: "provider.uk"))
        // Half an hour earlier than the supplement programme the proxy judged.
        let earlier = listing(epg: "sky.uk", kickoff: helpers.now.addingTimeInterval(-1800))
        earlier.title = "Live football"
        earlier.subtitle = "Arsenal v Leeds United"
        container.mainContext.insert(earlier)
        try container.mainContext.save()
        let result = await SportsChannelResolver.resolve(container: container, fixtures: [helpers.fixture()], proxyClient: client)
        #expect(result["401"]?.map(\.stream.name) == ["Sky Sports", "Provider Sports"])
        #expect(result["401"]?.allSatisfy { !$0.isConfident } == true)
    }

    @Test func `cache proof changes when proxy data becomes ready or disappears`() throws {
        let helpers = LumeSportsClientTests()
        let batch = try #require(try LumeSportsBatch.decode(Data(helpers.body().utf8)))
        let item = try #require(batch.items.first?.value)
        let game = helpers.fixture()
        let playlistID = UUID()
        let keys = SportsChannelResolver.proxyCacheKeys([playlistID: [game.id: item]], fixtures: [game])
        let localKey = SportsChannelResolver.ResolveCache.key(for: game)
        let proxyKey = SportsChannelResolver.ResolveCache.key(for: game, proxyKey: keys[game.id])
        #expect(localKey != proxyKey)
        #expect(SportsChannelResolver.proxyCacheKeys([:], fixtures: [game]).isEmpty)
        // Surface batch composition must not invalidate this fixture's answer.
        let larger = SportsChannelResolver.proxyCacheKeys([playlistID: [game.id: item]], fixtures: [game, helpers.fixture(id: "402")])
        #expect(larger[game.id] == keys[game.id])
    }
}
