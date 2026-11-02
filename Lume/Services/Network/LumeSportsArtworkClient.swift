import Foundation

/// Optional, bounded publication reads. Sportarr itself is only contacted by
/// the household proxy; image bytes use the app's ordinary public image cache.
actor LumeSportsArtworkClient {
    static let shared = LumeSportsArtworkClient()

    private struct Cached {
        let batch: LumeSportsArtworkBatch?
        let until: Date
    }

    private struct Flight {
        let id = UUID()
        let task: Task<LumeSportsArtworkBatch?, Never>
    }

    private let session: URLSession
    private let capabilities: LumeProxyCapabilityStore
    private var cache: [URL: Cached] = [:]
    private var order: [URL] = []
    private var flights: [URL: Flight] = [:]
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

    func artwork(source: LumeProxySource, fixtures: [SportsFixture], now: Date = Date()) async throws -> [String: LumeSportsArtworkPublication] {
        try Task.checkCancellation()
        let groups = Dictionary(grouping: fixtures.filter { $0.proxyCompetition != nil }, by: { $0.proxyCompetition ?? "" })
        guard !groups.isEmpty else { return [:] }
        failures = failures.filter { now < $0.value }
        guard failures[source.identity] == nil else { return [:] }
        let state = try await capabilities.capabilities(for: source, now: now)
        guard case let .supported(capability) = state, capability.version == 1,
              let artwork = capability.sportsArtwork, let limit = artwork.batchSize else { return [:] }
        var result: [String: LumeSportsArtworkPublication] = [:]
        var remaining = 8
        for competition in groups.keys.sorted() where artwork.competitions.contains(competition) {
            let fixtures = groups[competition] ?? []
            let ids = Set(fixtures.map(\.eventId)).sorted()
            for offset in stride(from: 0, to: ids.count, by: limit) {
                try Task.checkCancellation()
                guard remaining > 0 else { return result }
                remaining -= 1
                let chunk = Array(ids[offset ..< min(offset + limit, ids.count)])
                guard let url = source.sportsArtworkURL(competition: competition, ids: chunk) else { continue }
                guard let batch = await read(url, now: now) else {
                    if failures.count >= 64 { failures.removeAll() }
                    failures[source.identity] = now.addingTimeInterval(30)
                    return result
                }
                try Task.checkCancellation()
                let requested = fixtures.filter { chunk.contains($0.eventId) }
                result.merge(batch.validated(for: requested, competition: competition, now: now)) { _, new in new }
            }
        }
        return result
    }

    private func read(_ url: URL, now: Date) async -> LumeSportsArtworkBatch? {
        if let value = cache[url], now < value.until { return value.batch }
        let flight: Flight
        if let existing = flights[url] {
            flight = existing
        } else {
            // Independent surfaces coalesce; a huge fixture selection cannot
            // queue an unbounded number of optional network tasks.
            guard flights.count < 4 else { return nil }
            let session = session
            flight = Flight(task: Task {
                let request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 3)
                guard let (data, response) = try? await BoundedResponse.data(
                    for: request, session: session, limit: 256 * 1024, bodyPolicy: .successful
                ), (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
                return try? LumeSportsBatch.decoder().decode(LumeSportsArtworkBatch.self, from: data)
            })
            flights[url] = flight
        }
        let batch = await flight.task.value
        if flights[url]?.id == flight.id {
            flights.removeValue(forKey: url)
            let until: Date = if let batch, batch.status == "ready", now < batch.expiresAt {
                min(now.addingTimeInterval(300), batch.expiresAt)
            } else {
                // Unavailable publications retain their old expiry on the
                // wire. That stamp bounds artwork, not the negative cache.
                now.addingTimeInterval(30)
            }
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
