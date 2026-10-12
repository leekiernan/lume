import Foundation

/// Fast reads of background publications only. A miss never suppresses the
/// local matcher. Account-scoped, bounded cache; no authenticated URLs logged.
actor LumeSportsClient {
    static let shared = LumeSportsClient()

    private struct Cached {
        let batch: LumeSportsBatch?
        let until: Date
    }

    private struct Flight {
        let id = UUID()
        let task: Task<LumeSportsBatch?, Never>
    }

    private let session: URLSession
    private let capabilities: LumeProxyCapabilityStore
    private var cache: [URL: Cached] = [:]
    private var order: [URL] = []
    private var inFlight: [URL: Flight] = [:]

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
        var groups: [String: [SportsFixture]] = [:]
        for fixture in fixtures {
            if let competition = fixture.proxyCompetition { groups[competition, default: []].append(fixture) }
        }
        guard !groups.isEmpty else { return [:] }
        guard case let .supported(capability) = try await capabilities.capabilities(for: source, now: now),
              let limit = capability.sportsBatchSize, let sports = capability.sports else { return [:] }
        var result: [String: LumeSportsBroadcast] = [:]
        for competition in groups.keys.sorted() where sports.competitions.contains(competition) {
            let fixtures = groups[competition] ?? []
            let ids = Set(fixtures.map(\.eventId)).sorted()
            for offset in stride(from: 0, to: ids.count, by: limit) {
                try Task.checkCancellation()
                let chunk = Array(ids[offset ..< min(offset + limit, ids.count)])
                guard let url = source.sportsURL(competition: competition, ids: chunk) else { continue }
                let batch = await read(url, now: now)
                try Task.checkCancellation()
                let requested = fixtures.filter { chunk.contains($0.eventId) }
                result.merge(batch?.broadcasts(for: requested, competition: competition, now: now) ?? [:]) { _, new in new }
            }
        }
        return result
    }

    private func read(_ url: URL, now: Date) async -> LumeSportsBatch? {
        if let cached = cache[url], now < cached.until { return cached.batch }
        let flight: Flight
        if let existing = inFlight[url] {
            flight = existing
        } else {
            let session = session
            flight = Flight(task: Task {
                do {
                    let request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 3)
                    let (data, response) = try await session.data(for: request)
                    guard (response as? HTTPURLResponse)?.statusCode == 200, data.count <= 8 * 1024 * 1024 else { return nil }
                    return LumeSportsBatch.decode(data)
                } catch { return nil }
            })
            inFlight[url] = flight
        }
        let batch = await flight.task.value
        if inFlight[url]?.id == flight.id {
            inFlight.removeValue(forKey: url)
            // Ready data is reused briefly, never beyond publication expiry.
            // Pending/failures retry sooner and never turn into channel negatives.
            let lifetime: TimeInterval = batch?.status == "ready" ? 60 : 10
            let until = min(now.addingTimeInterval(lifetime), batch?.expiresAt ?? now.addingTimeInterval(lifetime))
            cache[url] = Cached(batch: batch, until: until)
            order.removeAll { $0 == url }
            order.append(url)
            while order.count > 16 {
                cache.removeValue(forKey: order.removeFirst())
            }
        }
        return batch
    }
}
