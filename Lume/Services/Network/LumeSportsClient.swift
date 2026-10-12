import Foundation

/// Fast reads of background publications only. A miss never suppresses the
/// local matcher. Account-scoped, bounded cache; no authenticated URLs logged.
actor LumeSportsClient {
    static let shared = LumeSportsClient()

    private struct Cached {
        let batch: LumeSportsBatch?
        let until: Date
        let byteCount: Int
    }

    private struct Payload {
        var batch: LumeSportsBatch?
        var byteCount = 0
        /// The proxy itself didn't answer (transport error or 5xx), so every
        /// account behind that host is out, not only the one that asked.
        var hostDown = false
    }

    private struct Flight {
        let id = UUID()
        let task: Task<Payload, Never>
    }

    private let session: URLSession
    private let capabilities: LumeProxyCapabilityStore
    private var cache: [URL: Cached] = [:]
    private var order: [URL] = []
    private var inFlight: [URL: Flight] = [:]
    private var failures: [String: Date] = [:]

    init(session: URLSession? = nil, capabilities: LumeProxyCapabilityStore = .shared) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpMaximumConnectionsPerHost = 2
        configuration.timeoutIntervalForRequest = 3
        configuration.timeoutIntervalForResource = 5
        configuration.httpAdditionalHeaders = ["User-Agent": lumeCatalogUserAgent]
        self.session = session ?? URLSession(configuration: configuration)
        self.capabilities = capabilities
    }

    func broadcasts(
        source: LumeProxySource, fixtures: [SportsFixture], now: Date = Date()
    ) async throws -> [String: LumeSportsBroadcast] {
        try Task.checkCancellation()
        let host = source.hostKey
        guard !coolingDown(source, now: now) else { return [:] }
        var groups: [String: [SportsFixture]] = [:]
        for fixture in fixtures {
            if let competition = fixture.proxyCompetition { groups[competition, default: []].append(fixture) }
        }
        guard !groups.isEmpty else { return [:] }
        let negotiation = try await capabilities.negotiation(for: source, now: now)
        if negotiation.state == .unavailable {
            failures[negotiation.hostDown ? host : source.identity] = now.addingTimeInterval(Self.cooldown)
        }
        guard case let .supported(capability) = negotiation.state,
              let limit = capability.sportsBatchSize, let sports = capability.sports else { return [:] }
        var result: [String: LumeSportsBroadcast] = [:]
        for competition in groups.keys.sorted() where sports.competitions.contains(competition) {
            let fixtures = groups[competition] ?? []
            let ids = Set(fixtures.map(\.eventId)).sorted()
            for offset in stride(from: 0, to: ids.count, by: limit) {
                try Task.checkCancellation()
                let chunk = Array(ids[offset ..< min(offset + limit, ids.count)])
                guard let url = source.sportsURL(competition: competition, ids: chunk) else { continue }
                let payload = await read(url, now: now)
                try Task.checkCancellation()
                guard let batch = payload.batch else {
                    // An optional endpoint outage must not cost one timeout per
                    // batch, surface or playlist before local matching runs.
                    failures[payload.hostDown ? host : source.identity] = now.addingTimeInterval(Self.cooldown)
                    return result
                }
                let requested = fixtures.filter { chunk.contains($0.eventId) }
                result.merge(batch.broadcasts(for: requested, competition: competition, now: now)) { _, new in new }
            }
        }
        return result
    }

    private static let cooldown: TimeInterval = 10

    private func coolingDown(_ source: LumeProxySource, now: Date) -> Bool {
        failures = failures.filter { now < $0.value }
        if failures.count > 64 { failures.removeAll() }
        return failures[source.identity] != nil || failures[source.hostKey] != nil
    }

    private func read(_ url: URL, now: Date) async -> Payload {
        if let cached = cache[url], now < cached.until { return Payload(batch: cached.batch, byteCount: cached.byteCount) }
        let flight: Flight
        if let existing = inFlight[url] {
            flight = existing
        } else {
            let session = session
            flight = Flight(task: Task {
                do {
                    let request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 3)
                    let (data, response) = try await session.data(for: request)
                    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                    guard status == 200, data.count <= 8 * 1024 * 1024 else { return Payload(hostDown: status >= 500) }
                    return Payload(batch: LumeSportsBatch.decode(data), byteCount: data.count)
                } catch { return Payload(hostDown: true) }
            })
            inFlight[url] = flight
        }
        let payload = await flight.task.value
        let batch = payload.batch
        if inFlight[url]?.id == flight.id {
            inFlight.removeValue(forKey: url)
            // Ready data is reused briefly, never beyond publication expiry.
            // Pending/failures retry sooner and never turn into channel negatives.
            let lifetime: TimeInterval = batch?.status == "ready" ? 60 : 10
            let until = min(now.addingTimeInterval(lifetime), batch?.expiresAt ?? now.addingTimeInterval(lifetime))
            cache[url] = Cached(batch: batch, until: until, byteCount: payload.byteCount)
            order.removeAll { $0 == url }
            order.append(url)
            while order.count > 16 || cache.values.reduce(0, { $0 + $1.byteCount }) > 16 * 1024 * 1024 {
                cache.removeValue(forKey: order.removeFirst())
            }
        }
        return payload
    }
}

nonisolated extension LumeProxySource {
    /// The proxy server, shared by every account a household points at it.
    var hostKey: String {
        let url = capabilitiesURL
        return "\(url.scheme ?? "")://\(url.host ?? ""):\(url.port.map(String.init) ?? "")"
    }
}
