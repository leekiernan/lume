import Foundation
@testable import Lume
import Testing

@MainActor
struct LumeSportsArtworkTests {
    let fixtureBuilder = LumeSportsClientTests()
    let now = Date(timeIntervalSince1970: 1_793_534_400)
    let image = "https://sportarr.net/static/images/event/example/thumb.jpg?v=1"

    func fixture(id: String = "401", kickoff: Date? = nil, league: String = "espn:soccer/eng.1") -> SportsFixture {
        fixtureBuilder.fixture(id: id, kickoff: kickoff ?? now, league: league)
    }

    func item(id: String = "401", changes: [String: Any] = [:]) -> [String: Any] {
        var value: [String: Any] = [
            "event_id": id, "status": "matched",
            "fixture": ["source": "espn", "competition": "soccer/eng.1", "event_id": id,
                        "start": now.ISO8601Format(), "home": ["id": "1"], "away": ["id": "2"]],
            "artwork": ["thumb": image]
        ]
        value.merge(changes) { _, new in new }
        return value
    }

    func body(items: [[String: Any]]? = nil, changes: [String: Any] = [:]) throws -> String {
        var value: [String: Any] = [
            "v": 1, "matcher_v": 1, "source": "espn", "artwork_source": "sportarr", "competition": "soccer/eng.1", "status": "ready",
            "verified_at": now.addingTimeInterval(-60).ISO8601Format(),
            "expires_at": now.addingTimeInterval(3600).ISO8601Format(),
            "from": now.addingTimeInterval(-86400).ISO8601Format(), "to": now.addingTimeInterval(86400).ISO8601Format(),
            "items": items ?? [item()]
        ]
        value.merge(changes) { _, new in new }
        return try #require(String(data: JSONSerialization.data(withJSONObject: value), encoding: .utf8))
    }

    func client(body: String, status: Int = 200, capability: String? = nil) throws -> (LumeSportsArtworkClient, LumeProxySource, String) {
        let host = UUID().uuidString.lowercased() + ".example.com"
        let playlist = Playlist(name: "Proxy", serverURL: "https://\(host)/panel?token=one%26two", username: "u&one", password: "p?two")
        let source = try #require(LumeProxySource(playlist: playlist))
        let capability = capability ?? #"{"v":1,"sports_artwork":{"v":1,"matcher_v":1,"source":"espn","artwork_source":"sportarr","competitions":["soccer/eng.1"],"max_batch_size":50}}"#
        StubURLProtocol.register(host: host, pathSuffix: "/capabilities", response: .init(body: capability))
        StubURLProtocol.register(host: host, pathSuffix: "/sports/artwork", response: .init(status: status, body: body))
        let session = StubURLProtocol.makeSession()
        return (LumeSportsArtworkClient(session: session, capabilities: LumeProxyCapabilityStore(session: session)), source, host)
    }

    @Test func `artwork negotiates independently and keeps proxy credentials on its own request`() async throws {
        let (client, source, host) = try client(body: body())
        let values = try await client.artwork(source: source, fixtures: [fixture()], now: now)
        #expect(values["401"]?.value.artwork?.url(portrait: false)?.absoluteString == image)
        #expect(values["401"]?.expiresAt == now.addingTimeInterval(3600))
        let request = try #require(StubURLProtocol.requests(forHost: host).last)
        let url = try #require(request.url)
        let parts = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        #expect(parts.path == "/panel/lume/v1/sports/artwork")
        #expect(parts.queryItems?.contains(URLQueryItem(name: "password", value: "p?two")) == true)
        #expect(parts.queryItems?.contains(URLQueryItem(name: "token", value: "one&two")) == true)
        #expect(parts.queryItems?.contains(URLQueryItem(name: "ids", value: "401")) == true)
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
    }

    @Test(arguments: ["version", "matcher", "source", "artwork_source", "competition", "expired", "future", "long", "window", "pending", "malformed"])
    func `invalid publications preserve fallback`(_ field: String) async throws {
        let cases: [String: [String: Any]] = [
            "version": ["v": 2], "matcher": ["matcher_v": 2],
            "source": ["source": "other"], "artwork_source": ["artwork_source": "other"],
            "competition": ["competition": "soccer/eng.2"], "expired": ["expires_at": now.ISO8601Format()],
            "future": ["verified_at": now.addingTimeInterval(1).ISO8601Format()],
            "long": ["expires_at": now.addingTimeInterval(86400).ISO8601Format()],
            "window": ["to": now.ISO8601Format()], "malformed": ["verified_at": "not a date"], "pending": ["status": "pending"]
        ]
        let changes = try #require(cases[field])
        let (client, source, _) = try client(body: body(changes: changes))
        #expect(try await client.artwork(source: source, fixtures: [fixture()], now: now).isEmpty)
    }

    @Test(arguments: ["home", "away", "event_id", "competition", "start"])
    func `identity mismatches cannot decorate a different fixture`(_ field: String) async throws {
        var entry = item()
        var identity = try #require(entry["fixture"] as? [String: Any])
        identity[field] = field == "home" || field == "away" ? ["id": "999"] : "different"
        entry["fixture"] = identity
        let (client, source, _) = try client(body: body(items: [entry]))
        #expect(try await client.artwork(source: source, fixtures: [fixture()], now: now).isEmpty)
    }

    @Test func `duplicates abstain while malformed siblings do not discard good artwork`() async throws {
        let (client, source, _) = try client(body: body(items: [item(), ["event_id": "402", "status": false]]))
        #expect(try await client.artwork(source: source, fixtures: [fixture()], now: now).count == 1)
        let (duplicate, other, _) = try self.client(body: body(items: [item(), item()]))
        #expect(try await duplicate.artwork(source: other, fixtures: [fixture()], now: now).isEmpty)
        let (malformedDuplicate, third, _) = try self.client(body: body(items: [item(), ["event_id": "401", "status": false]]))
        #expect(try await malformedDuplicate.artwork(source: third, fixtures: [fixture()], now: now).isEmpty)
    }

    @Test func `rescheduling invalidates both response and presentation cache`() async throws {
        let (client, source, _) = try client(body: body())
        let values = try await client.artwork(source: source, fixtures: [fixture()], now: now)
        let store = SportsArtworkEnrichment()
        store.publish(values, now: now)
        #expect(store.images(for: fixture(), now: now) != nil)
        #expect(store.images(for: fixture(kickoff: now.addingTimeInterval(60)), now: now) == nil)
        #expect(try await client.artwork(source: source, fixtures: [fixture(kickoff: now.addingTimeInterval(60))], now: now).isEmpty)
    }

    @Test func `cached reads and republishing retain original expiry`() async throws {
        let (client, source, host) = try client(body: body(changes: ["expires_at": now.addingTimeInterval(90).ISO8601Format()]))
        let first = try await client.artwork(source: source, fixtures: [fixture()], now: now)
        let later = try await client.artwork(source: source, fixtures: [fixture()], now: now.addingTimeInterval(60))
        #expect(first == later)
        #expect(StubURLProtocol.requests(forHost: host).count == 2)
        let store = SportsArtworkEnrichment()
        store.publish(first, now: now)
        store.publish(later, now: now.addingTimeInterval(60))
        #expect(store.images(for: fixture(), now: now.addingTimeInterval(90)) == nil)
        #expect(try await client.artwork(source: source, fixtures: [fixture()], now: now.addingTimeInterval(90)).isEmpty)
    }

    @Test(arguments: ["unmatched", "ambiguous"])
    func `a confirmed retraction removes old art while an outage retains it`(_ status: String) async throws {
        let (client, source, host) = try client(body: body())
        let first = try await client.artwork(source: source, fixtures: [fixture()], now: now)
        let store = SportsArtworkEnrichment()
        store.publish(first, now: now)
        #expect(store.images(for: fixture(), now: now) != nil)
        StubURLProtocol.register(host: host, pathSuffix: "/sports/artwork", response: .init(status: 503))
        let afterFailure = now.addingTimeInterval(301)
        try await store.publish(client.artwork(source: source, fixtures: [fixture()], now: afterFailure), now: afterFailure)
        #expect(store.images(for: fixture(), now: afterFailure) != nil)
        let retraction = try body(items: [item(changes: ["status": status, "artwork": NSNull()])])
        StubURLProtocol.register(host: host, pathSuffix: "/sports/artwork", response: .init(body: retraction))
        let afterRetraction = now.addingTimeInterval(332)
        try await store.publish(client.artwork(source: source, fixtures: [fixture()], now: afterRetraction), now: afterRetraction)
        #expect(store.images(for: fixture(), now: afterRetraction) == nil)
    }

    @Test func `a retained answer is discarded if its source changes during a later read`() async throws {
        let (client, source, _) = try client(body: body())
        let values = try await client.artwork(source: source, fixtures: [fixture()], now: now)
        let (_, other, _) = try self.client(body: body())
        let answers = [(source, values), (other, [:])]
        #expect(SportsArtworkEnrichment.merged(answers, currentSources: [source, other]) == values)
        #expect(SportsArtworkEnrichment.merged(answers, currentSources: [other]).isEmpty)
    }

    @Test(arguments: [401, 404, 429, 503])
    func `HTTP failures back off the whole selection`(_ status: Int) async throws {
        let (client, source, host) = try client(body: "", status: status)
        #expect(try await client.artwork(source: source, fixtures: [fixture()], now: now).isEmpty)
        #expect(try await client.artwork(source: source, fixtures: [fixture(id: "402")], now: now.addingTimeInterval(29)).isEmpty)
        #expect(StubURLProtocol.requests(forHost: host).count == 2)
    }

    @Test(arguments: [
        #"{"v":1,"sports":{"v":1,"matcher_v":3,"source":"espn","competitions":["soccer/eng.1"],"max_batch_size":50,"groups":["broadcasts"]}}"#,
        #"{"v":1,"sports_artwork":{"v":2}}"#,
        #"{"v":1,"sports_artwork":false}"#
    ])
    func `older and incompatible proxies make no artwork request`(_ capability: String) async throws {
        let (client, source, host) = try client(body: body(), capability: capability)
        #expect(try await client.artwork(source: source, fixtures: [fixture()], now: now).isEmpty)
        #expect(StubURLProtocol.requests(forHost: host).count == 1)
    }

    @Test func `non football and cancellation make no requests`() async throws {
        let (client, source, host) = try client(body: body())
        #expect(try await client.artwork(source: source, fixtures: [fixture(league: "espn:mma/ufc")], now: now).isEmpty)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await client.artwork(source: source, fixtures: [fixture()], now: now)
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(StubURLProtocol.requests(forHost: host).isEmpty)
    }

    @Test func `canonical batches are bounded and repeated concurrently requested IDs coalesce`() async throws {
        let (client, source, host) = try client(body: body())
        let fixtures = (1 ... 501).map { fixture(id: String($0)) }
        async let first = client.artwork(source: source, fixtures: fixtures + [fixtures[0]], now: now)
        async let second = client.artwork(source: source, fixtures: fixtures, now: now)
        _ = try await (first, second)
        let requests = StubURLProtocol.requests(forHost: host).filter { $0.url?.path.hasSuffix("/artwork") == true }
        #expect(requests.count == 8)
        for request in requests {
            let url = try #require(request.url)
            let parts = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
            let ids = try #require(parts.queryItems?.first { $0.name == "ids" }?.value).split(separator: ",")
            #expect(ids.count <= 50)
            #expect(ids == ids.sorted())
        }
    }

    @Test func `oversized publications are refused`() async throws {
        let (client, source, _) = try client(body: String(repeating: " ", count: 256 * 1024 + 1))
        #expect(try await client.artwork(source: source, fixtures: [fixture()], now: now).isEmpty)
        let (tooMany, other, _) = try self.client(body: body(items: (1 ... 51).map { item(id: String($0)) }))
        #expect(try await tooMany.artwork(source: other, fixtures: [fixture()], now: now).isEmpty)
    }

    @Test(arguments: [
        "http://sportarr.net/static/images/event/a.jpg", "https://evil.example/a.jpg",
        "https://sportarr.net.evil.example/static/images/event/a.jpg", "https://user:password@sportarr.net/static/images/event/a.jpg",
        "https://sportarr.net:443/static/images/event/a.jpg", "https://sportarr.net/static/images/event/a.jpg#token",
        "https://sportarr.net/static/images/event/a.jpg?api_key=secret", "https://sportarr.net/api/public/v1/events",
        "https://sportarr.net/static/images/event/a.jpg?v=https://example.com/secret", "https://sportarr.net/static/images/event/a.jpg?v=1&v=2",
        "https://sportarr.net/static/images/event/%2e%2e/private.jpg", "https://r2.thesportsdb.com/images/media/event/a.jpg?token=secret"
    ])
    func `unapproved and credential bearing images are rejected`(_ raw: String) {
        #expect(LumeSportsArtwork.Images.allowed(URL(string: raw)) == nil)
    }

    @Test func `portrait and landscape selection does not rewrite public image URLs`() throws {
        let raw = "{\"poster\":\"https://sportarr.net/static/images/event/a/poster.jpg?v=2\",\"thumb\":\"\(image)\"}"
        let images = try JSONDecoder().decode(LumeSportsArtwork.Images.self, from: Data(raw.utf8))
        #expect(images.url(portrait: true)?.lastPathComponent == "poster.jpg")
        #expect(images.url(portrait: false)?.absoluteString == image)
        let poster = try #require(images.url(portrait: true))
        let thumb = try #require(URL(string: image))
        #expect(images.url(portrait: true, excluding: [poster])?.absoluteString == image)
        #expect(images.url(portrait: true, excluding: [poster, thumb]) == nil)
    }
}
