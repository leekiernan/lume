import Foundation
@testable import Lume
import SwiftData
import Testing

@MainActor
struct LumeSportsArtworkScopeTests {
    let factory = LumeSportsArtworkTests()

    @Test(arguments: ["football/nfl", "basketball/nba", "hockey/nhl"])
    func `advertised US artwork renders without enabling football broadcast matching`(_ competition: String) async throws {
        let fixture = factory.fixture(league: "espn:\(competition)")
        var entry = factory.item()
        var identity = try #require(entry["fixture"] as? [String: Any])
        identity["competition"] = competition
        entry["fixture"] = identity
        let body = try factory.body(items: [entry], changes: ["competition": competition])
        let capability = """
        {"v":1,"sports_artwork":{"v":1,"matcher_v":1,"source":"espn","artwork_source":"sportarr","competitions":["\(competition)"],"max_batch_size":50}}
        """
        let (client, source, host) = try factory.client(body: body, capability: capability)
        let values = try await client.artwork(source: source, fixtures: [fixture], now: factory.now)
        #expect(values["401"]?.value.fixture.competition == competition)
        #expect(fixture.proxyCompetition == nil)
        #expect(fixture.artworkCompetition == competition)
        let returned = try #require(values["401"]?.value.fixture)
        #expect(!returned.matches(fixture))
        #expect(returned.matches(fixture, competition: fixture.artworkCompetition))
        let store = SportsArtworkEnrichment()
        store.publish(values, now: factory.now)
        #expect(store.images(for: fixture, now: factory.now)?.url(portrait: false)?.absoluteString == factory.image)
        #expect(store.images(for: factory.fixture(league: "espn:soccer/eng.1"), now: factory.now) == nil)
        #expect(store.images(for: factory.fixture(kickoff: factory.now.addingTimeInterval(1), league: "espn:\(competition)"), now: factory.now) == nil)
        let paths = StubURLProtocol.requests(forHost: host).compactMap { $0.url?.lastPathComponent }
        #expect(paths == ["capabilities", "artwork"])
    }

    @Test func `ordinary football proxy does not receive US artwork requests`() async throws {
        let (client, source, host) = try factory.client(body: factory.body())
        let values = try await client.artwork(source: source, fixtures: [factory.fixture(league: "espn:basketball/nba")], now: factory.now)
        #expect(values.isEmpty)
        #expect(StubURLProtocol.requests(forHost: host).count == 1)
    }

    @Test func `a same ID response from another competition is rejected`() async throws {
        let capability = #"{"v":1,"sports_artwork":{"v":1,"matcher_v":1,"source":"espn","artwork_source":"sportarr","competitions":["basketball/nba"],"max_batch_size":50}}"#
        let (client, source, _) = try factory.client(body: factory.body(changes: ["competition": "basketball/nba"]), capability: capability)
        #expect(try await client.artwork(source: source, fixtures: [factory.fixture(league: "espn:basketball/nba")], now: factory.now).isEmpty)
    }

    @Test func `artwork account snapshots work without a football fixture`() async throws {
        let container = try makeTestContainer()
        let playlist = Playlist(name: "Proxy", serverURL: "https://example.com", username: "test", password: "test")
        container.mainContext.insert(playlist)
        try container.mainContext.save()
        let fixture = factory.fixture(league: "espn:hockey/nhl")
        let (artwork, broadcasts) = await Task.detached {
            (LumeProxySource.snapshots(in: container), SportsChannelResolver.proxySources(container: container, fixtures: [fixture]))
        }.value
        #expect(artwork.map(\.playlistID) == [playlist.id])
        #expect(broadcasts.isEmpty)
    }
}
