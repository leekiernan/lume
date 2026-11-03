import Foundation
@testable import Lume
import Testing

/// Raw responses captured from the sibling proxy's actual HTTP handlers.
/// See Fixtures/ProxySportsArtwork/PROVENANCE.md for provenance and scope.
@MainActor
struct LumeSportsArtworkContractTests {
    private final class ResourceAnchor {}
    private nonisolated struct Reference: Decodable { let now: Date }

    private func body(_ name: String) throws -> String {
        let bundle = Bundle(for: ResourceAnchor.self)
        let source = URL(fileURLWithPath: #filePath).resolvingSymlinksInPath()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/ProxySportsArtwork/\(name).json")
        let url = bundle.url(forResource: name, withExtension: "json", subdirectory: "Fixtures/ProxySportsArtwork")
            ?? bundle.url(forResource: name, withExtension: "json") ?? source
        return try String(contentsOf: url, encoding: .utf8)
    }

    private func reference() throws -> (SportsFixture, Date) {
        let decoder = LumeSportsBatch.decoder()
        let batch = try decoder.decode(LumeSportsArtworkBatch.self, from: Data(body("matched").utf8))
        let identity = try #require(batch.items.first?.value?.fixture)
        let clock = try decoder.decode(Reference.self, from: Data(body("reference").utf8))
        return (LumeSportsClientTests().fixture(kickoff: identity.start), clock.now)
    }

    @Test func `actual proxy capabilities advertise artwork only when enabled`() throws {
        let decoder = JSONDecoder()
        let enabled = try decoder.decode(LumeProxyCapabilities.self, from: Data(body("capabilities-enabled").utf8))
        let disabled = try decoder.decode(LumeProxyCapabilities.self, from: Data(body("capabilities-disabled").utf8))
        #expect(enabled.sportsArtwork?.batchSize == 50)
        #expect(enabled.sportsArtwork?.competitions == ["soccer/eng.1"])
        #expect(disabled.sportsArtwork == nil)
        #expect(enabled.sportsBatchSize == disabled.sportsBatchSize)
        #expect(enabled.metadata == disabled.metadata)
    }

    @Test func `actual matched publication is delivered and unknown events stay absent`() async throws {
        let (fixture, now) = try reference()
        let (client, source, _) = try LumeSportsArtworkTests().client(body: body("matched"), capability: body("capabilities-enabled"))
        let missing = LumeSportsClientTests().fixture(id: "999", kickoff: fixture.startDate)
        let values = try await client.artwork(source: source, fixtures: [fixture, missing], now: now)
        #expect(Set(values.keys) == ["401"])
        #expect(values["401"]?.value.artwork?.url(portrait: false)?.absoluteString ==
            "https://sportarr.net/static/images/event/b5/b56b/thumbnail_thesportsdb_7639.jpg?v=g1-7639")
        let batch = try LumeSportsBatch.decoder().decode(LumeSportsArtworkBatch.self, from: Data(body("matched").utf8))
        #expect(values["401"]?.expiresAt == batch.expiresAt)
    }

    @Test(arguments: ["pending", "unavailable"])
    func `actual nonready publications retain fallback and bound retries`(_ name: String) async throws {
        let (fixture, now) = try reference()
        let (client, source, host) = try LumeSportsArtworkTests().client(body: body(name), capability: body("capabilities-enabled"))
        #expect(try await client.artwork(source: source, fixtures: [fixture], now: now).isEmpty)
        #expect(try await client.artwork(source: source, fixtures: [fixture], now: now.addingTimeInterval(1)).isEmpty)
        #expect(StubURLProtocol.requests(forHost: host).count == 2)
    }

    @Test(arguments: ["unmatched", "ambiguous", "matched-without-images"])
    func `actual ready noimage publications retract a previous image`(_ name: String) async throws {
        let (fixture, now) = try reference()
        let factory = LumeSportsArtworkTests()
        let (firstClient, firstSource, _) = try factory.client(body: body("matched"), capability: body("capabilities-enabled"))
        let store = SportsArtworkEnrichment()
        try await store.publish(firstClient.artwork(source: firstSource, fixtures: [fixture], now: now), now: now)
        #expect(store.images(for: fixture, now: now)?.url(portrait: false) != nil)
        let (client, source, _) = try factory.client(body: body(name), capability: body("capabilities-enabled"))
        let values = try await client.artwork(source: source, fixtures: [fixture], now: now)
        #expect(Set(values.keys) == ["401"])
        store.publish(values, now: now)
        #expect(store.images(for: fixture, now: now)?.url(portrait: false) == nil)
    }

    @Test func `actual disabled capability never probes the artwork route`() async throws {
        let (fixture, now) = try reference()
        let (client, source, host) = try LumeSportsArtworkTests().client(body: body("matched"), capability: body("capabilities-disabled"))
        #expect(try await client.artwork(source: source, fixtures: [fixture], now: now).isEmpty)
        #expect(StubURLProtocol.requests(forHost: host).count == 1)
    }
}
