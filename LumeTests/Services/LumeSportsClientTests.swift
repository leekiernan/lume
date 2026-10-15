import Foundation
@testable import Lume
import Testing

@MainActor
struct LumeSportsClientTests {
    let now = Date()

    func fixture(id: String = "401", kickoff: Date? = nil, league: String = "espn:soccer/eng.1") -> SportsFixture {
        SportsFixture(
            id: id, leagueId: league, leagueName: "Premier League", leagueAbbreviation: "EPL",
            startDate: kickoff ?? now, status: SportsFixtureStatus(state: .scheduled),
            home: SportsCompetitor(team: SportsTeam(leagueId: league, teamId: "1", name: "Arsenal", shortName: "Arsenal", abbreviation: "ARS")),
            away: SportsCompetitor(team: SportsTeam(leagueId: league, teamId: "2", name: "Leeds United", shortName: "Leeds", abbreviation: "LEE"))
        )
    }

    func item(id: String = "401", candidates: [[String: Any]]? = nil) -> [String: Any] {
        [
            "event_id": id, "status": "ready",
            "fixture": ["source": "espn", "competition": "soccer/eng.1", "event_id": id,
                        "start": date(now), "home": ["id": "1"], "away": ["id": "2"]],
            "candidates": candidates ?? [candidate()]
        ]
    }

    func candidate(streamID: Int = 123, strength: String = "explicit_pairing") -> [String: Any] {
        ["stream_id": streamID, "category_id": "7", "epg_id": "sky.uk", "name": "Sky Sports",
         "evidence": ["source": "supplement:uk", "field": "title", "text": "Arsenal v Leeds United",
                      "strength": strength, "classification": "live", "programme_id": "programme-1",
                      "start": date(now), "stop": date(now.addingTimeInterval(7200))]]
    }

    func date(_ date: Date) -> String {
        date.ISO8601Format()
    }

    func body(items: [[String: Any]]? = nil, changes: [String: Any] = [:]) throws -> String {
        var json: [String: Any] = [
            "v": 1, "matcher_v": 3, "source": "espn", "competition": "soccer/eng.1", "status": "ready",
            "verified_at": date(now.addingTimeInterval(-60)), "expires_at": date(now.addingTimeInterval(3600)),
            "from": date(now.addingTimeInterval(-86400)), "to": date(now.addingTimeInterval(7 * 86400)),
            "items": items ?? [item()]
        ]
        json.merge(changes) { _, new in new }
        return try #require(String(data: JSONSerialization.data(withJSONObject: json), encoding: .utf8))
    }

    func client(body: String, status: Int = 200, capability: String? = nil) throws -> (LumeSportsClient, LumeProxySource, String) {
        let host = UUID().uuidString.lowercased() + ".example.com"
        let playlist = Playlist(name: "Proxy", serverURL: "https://\(host)/panel?token=one%26two", username: "u&one", password: "p?two")
        let source = try #require(LumeProxySource(playlist: playlist))
        let capability = capability ?? #"{"v":1,"sports":{"v":1,"matcher_v":3,"source":"espn","competitions":["soccer/eng.1"],"max_batch_size":50,"groups":["broadcasts"]}}"#
        StubURLProtocol.register(host: host, pathSuffix: "/capabilities", response: .init(body: capability))
        StubURLProtocol.register(host: host, pathSuffix: "/sports/broadcasts", response: .init(status: status, body: body))
        let session = StubURLProtocol.makeSession()
        return (LumeSportsClient(session: session, capabilities: LumeProxyCapabilityStore(session: session)), source, host)
    }

    @Test func `fresh response is account scoped cached and preserves the endpoint query`() async throws {
        let (client, source, host) = try client(body: body())
        let first = try await client.broadcasts(source: source, fixtures: [fixture()], now: now)
        #expect(first["401"]?.candidates?.first?.streamID == 123)
        #expect(try await client.broadcasts(source: source, fixtures: [fixture()], now: now.addingTimeInterval(59)) == first)
        let requests = StubURLProtocol.requests(forHost: host).filter { $0.url?.path.hasSuffix("/broadcasts") == true }
        #expect(requests.count == 1)
        let url = try #require(requests.first?.url)
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        #expect(components.path == "/panel/lume/v1/sports/broadcasts")
        #expect(components.queryItems?.contains(URLQueryItem(name: "password", value: "p?two")) == true)
        #expect(components.queryItems?.contains(URLQueryItem(name: "competition", value: "soccer/eng.1")) == true)
        #expect(components.queryItems?.contains(URLQueryItem(name: "token", value: "one&two")) == true)
    }

    @Test(arguments: ["expired", "future", "source", "competition", "version", "matcher", "pending", "unavailable", "window"])
    func `untrusted or stale publications fall back`(_ field: String) async throws {
        let changes: [String: Any] = switch field {
        case "expired": ["expires_at": date(now)]
        case "future": ["verified_at": date(now.addingTimeInterval(1))]
        case "source": ["source": "other"]
        case "competition": ["competition": "soccer/eng.2"]
        case "version": ["v": 2]
        case "matcher": ["matcher_v": 4]
        case "window": ["to": date(now)]
        default: ["status": field]
        }
        let (client, source, _) = try client(body: body(changes: changes))
        #expect(try await client.broadcasts(source: source, fixtures: [fixture()], now: now).isEmpty)
    }

    @Test func `one malformed item does not discard a valid sibling`() async throws {
        let (client, source, _) = try client(body: body(items: [item(), ["event_id": "402", "status": false]]))
        let values = try await client.broadcasts(source: source, fixtures: [fixture(), fixture(id: "402")], now: now)
        #expect(Set(values.keys) == ["401"])
    }

    @Test func `rescheduled and duplicate event identities are rejected`() async throws {
        let (client, source, _) = try client(body: body())
        #expect(try await client.broadcasts(source: source, fixtures: [fixture(kickoff: now.addingTimeInterval(60))], now: now).isEmpty)
        let (duplicateClient, duplicateSource, _) = try self.client(body: body(items: [item(), item()]))
        #expect(try await duplicateClient.broadcasts(source: duplicateSource, fixtures: [fixture()], now: now).isEmpty)
    }

    @Test(arguments: [401, 404, 500, 503])
    func `HTTP failures stay optional`(_ status: Int) async throws {
        let (client, source, _) = try client(body: "", status: status)
        #expect(try await client.broadcasts(source: source, fixtures: [fixture()], now: now).isEmpty)
    }

    @Test func `non football makes no capability or broadcast requests`() async throws {
        let (client, source, host) = try client(body: body())
        #expect(try await client.broadcasts(source: source, fixtures: [fixture(league: "espn:mma/ufc")], now: now).isEmpty)
        #expect(StubURLProtocol.requests(forHost: host).isEmpty)
    }

    @Test func `ordinary provider never gets a broadcast request`() async throws {
        let (client, source, host) = try client(body: body(), capability: #"{"v":1,"metadata":{"v":1,"max_batch_size":50}}"#)
        #expect(try await client.broadcasts(source: source, fixtures: [fixture()], now: now).isEmpty)
        #expect(StubURLProtocol.requests(forHost: host).count == 1)
    }

    @Test func `cache never extends publication expiry and pending retries soon`() async throws {
        let (client, source, host) = try client(body: body(changes: ["expires_at": date(now.addingTimeInterval(5))]))
        #expect(try await client.broadcasts(source: source, fixtures: [fixture()], now: now).count == 1)
        #expect(try await client.broadcasts(source: source, fixtures: [fixture()], now: now.addingTimeInterval(6)).isEmpty)
        #expect(StubURLProtocol.requests(forHost: host).count == 3)
        let (pending, pendingSource, pendingHost) = try self.client(body: body(changes: ["status": "pending"]))
        _ = try await pending.broadcasts(source: pendingSource, fixtures: [fixture()], now: now)
        try StubURLProtocol.register(host: pendingHost, pathSuffix: "/sports/broadcasts", response: .init(body: body()))
        #expect(try await pending.broadcasts(source: pendingSource, fixtures: [fixture()], now: now.addingTimeInterval(10)).count == 1)
    }

    @Test func `cancelled caller makes no request`() async throws {
        let (client, source, host) = try client(body: body())
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await client.broadcasts(source: source, fixtures: [fixture()], now: now)
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(StubURLProtocol.requests(forHost: host).isEmpty)
    }

    @Test func `large lists use canonical batches capped at fifty`() async throws {
        let (client, source, host) = try client(body: body())
        let fixtures = (1 ... 101).map { fixture(id: String($0)) }
        _ = try await client.broadcasts(source: source, fixtures: fixtures + [fixtures[0]], now: now)
        let reads = StubURLProtocol.requests(forHost: host).filter { $0.url?.path.hasSuffix("/broadcasts") == true }
        #expect(reads.count == 3)
        for read in reads {
            let url = try #require(read.url)
            let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
            let ids = try #require(components.queryItems?.first { $0.name == "ids" }?.value).split(separator: ",")
            #expect(ids.count <= 50)
            #expect(Set(ids).count == ids.count)
        }
    }

    @Test func `concurrent surfaces share a broadcast read`() async throws {
        let (client, source, host) = try client(body: body())
        let game = fixture()
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0 ..< 12 {
                group.addTask { _ = try await client.broadcasts(source: source, fixtures: [game]) }
            }
            try await group.waitForAll()
        }
        #expect(StubURLProtocol.requests(forHost: host).count(where: { $0.url?.path.hasSuffix("/broadcasts") == true }) == 1)
    }

    @Test func `different team identity and out of window evidence are rejected`() throws {
        var value = item()
        var fixture = try #require(value["fixture"] as? [String: Any])
        fixture["home"] = ["id": "999"]
        value["fixture"] = fixture
        let batch = try #require(try LumeSportsBatch.decode(Data(body(items: [value]).utf8)))
        #expect(batch.broadcasts(for: [self.fixture()], competition: "soccer/eng.1", now: now).isEmpty)
        var candidate = candidate()
        var evidence = try #require(candidate["evidence"] as? [String: Any])
        evidence["stop"] = date(now.addingTimeInterval(-1))
        candidate["evidence"] = evidence
        let invalid = try #require(try LumeSportsBatch.decode(Data(body(items: [item(candidates: [candidate])]).utf8)))
        let decoded = try #require(invalid.items.first?.value?.candidates?.first?.evidence)
        #expect(decoded.validated(kickoff: now) == nil)
    }

    @Test func `outage cooldown prevents timeout fanout across batches and surfaces`() async throws {
        let (client, source, host) = try client(body: "", status: 503)
        let games = (1 ... 101).map { fixture(id: String($0)) }
        #expect(try await client.broadcasts(source: source, fixtures: games, now: now).isEmpty)
        #expect(try await client.broadcasts(source: source, fixtures: [fixture()], now: now.addingTimeInterval(9)).isEmpty)
        #expect(StubURLProtocol.requests(forHost: host).count(where: { $0.url?.path.hasSuffix("/broadcasts") == true }) == 1)
        try StubURLProtocol.register(host: host, pathSuffix: "/sports/broadcasts", response: .init(body: body()))
        #expect(try await client.broadcasts(source: source, fixtures: [fixture()], now: now.addingTimeInterval(10)).count == 1)
    }

    /// A down proxy is down for every account behind it; an account the proxy
    /// rejects is only that account's problem.
    @Test(arguments: [503, 401])
    func `a server outage cools the whole proxy host, an account error only that account`(_ status: Int) async throws {
        let (client, source, host) = try client(body: "", status: status)
        let other = Playlist(name: "Second account", serverURL: "https://\(host)/panel", username: "second", password: "secret")
        let second = try #require(LumeProxySource(playlist: other))
        #expect(second.hostKey == source.hostKey && second.identity != source.identity)
        #expect(try await client.broadcasts(source: source, fixtures: [fixture()], now: now).isEmpty)
        _ = try await client.broadcasts(source: second, fixtures: [fixture()], now: now.addingTimeInterval(1))
        let reads = StubURLProtocol.requests(forHost: host).count(where: { $0.url?.path.hasSuffix("/broadcasts") == true })
        #expect(reads == (status >= 500 ? 1 : 2))
    }

    @Test(arguments: [401, 403, 429, 503, 200])
    func `capability failures only cool the host for server outages`(_ status: Int) async throws {
        let (client, source, host) = try client(body: body())
        // The 200 case is malformed JSON, not an outage of other accounts.
        StubURLProtocol.register(host: host, pathSuffix: "/capabilities", response: .init(status: status, body: "invalid"))
        #expect(try await client.broadcasts(source: source, fixtures: [fixture()], now: now).isEmpty)
        let other = Playlist(name: "Second account", serverURL: "https://\(host)/panel", username: "second", password: "secret")
        let second = try #require(LumeProxySource(playlist: other))
        let capability = #"{"v":1,"sports":{"v":1,"matcher_v":3,"source":"espn","competitions":["soccer/eng.1"],"max_batch_size":50,"groups":["broadcasts"]}}"#
        StubURLProtocol.register(host: host, pathSuffix: "/capabilities", response: .init(body: capability))
        let result = try await client.broadcasts(source: second, fixtures: [fixture()], now: now.addingTimeInterval(1))
        #expect(result.isEmpty == (status >= 500))
        let probes = StubURLProtocol.requests(forHost: host).count(where: { $0.url?.path.hasSuffix("/capabilities") == true })
        #expect(probes == (status >= 500 ? 1 : 2))
    }
}
