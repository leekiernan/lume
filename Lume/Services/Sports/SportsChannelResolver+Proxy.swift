import Foundation
import OSLog
import SwiftData

nonisolated extension SportsChannelResolver {
    /// What the proxy adds to one fixture. It never replaces local matching:
    /// the proxy is stricter (no aliases, whole names only), so a playlist it
    /// answers for can still hold channels only the local matcher finds.
    struct ProxyPlan {
        var channels: [ResolvedChannel] = []
        var suggestionIDs: Set<String> = []
    }

    static func validatedProxyBroadcasts(
        container: ModelContainer, fixtures: [SportsFixture], client: LumeSportsClient
    ) async -> [UUID: [String: LumeSportsBroadcast]] {
        // No managed context or Playlist survives across this await.
        let sources = proxySources(container: container, fixtures: fixtures)
        let fetched = await proxyBroadcasts(sources: sources, fixtures: fixtures, client: client)
        guard !Task.isCancelled else { return [:] }
        // An account edit cannot apply old provider IDs to a replacement account.
        let currentSources = Set(proxySources(container: container, fixtures: fixtures))
        let validIDs = Set(sources.filter { currentSources.contains($0) }.map(\.playlistID))
        return fetched.filter { validIDs.contains($0.key) }
    }

    static func proxyPlans(
        fixtures: [SportsFixture], channels: [Channel], broadcasts: [UUID: [String: LumeSportsBroadcast]]
    ) -> [String: ProxyPlan] {
        guard !broadcasts.isEmpty else { return [:] }
        // Build the potentially large local channel index once, not per fixture.
        let visible = Dictionary(channels.map { ($0.summary.id, $0) }, uniquingKeysWith: { first, _ in first })
        let plans = Dictionary(uniqueKeysWithValues: fixtures.map {
            ($0.id, proxyPlan(fixture: $0, visible: visible, broadcasts: broadcasts))
        })
        let covered = plans.values.count(where: { $0.channels.contains { $0.matchedStart != nil } })
        let offered = plans.values.reduce(0) { $0 + $1.channels.count }
        Logger.network.info("Sports proxy: \(covered) of \(fixtures.count) fixtures have timed matches; \(offered) visible candidates")
        return plans
    }

    static func proxySources(container: ModelContainer, fixtures: [SportsFixture]) -> [LumeProxySource] {
        guard fixtures.contains(where: { $0.proxyCompetition != nil }) else { return [] }
        return autoreleasepool {
            let context = ModelContext(container)
            let playlists = (try? context.fetch(FetchDescriptor<Playlist>())) ?? []
            return playlists.compactMap { LumeProxySource(playlist: $0) }
        }
    }

    static func proxyBroadcasts(
        sources: [LumeProxySource], fixtures: [SportsFixture], client: LumeSportsClient
    ) async -> [UUID: [String: LumeSportsBroadcast]] {
        await withTaskGroup(of: (UUID, [String: LumeSportsBroadcast]).self) { group in
            var iterator = sources.makeIterator()
            func submit(_ source: LumeProxySource) {
                group.addTask {
                    let values = await (try? client.broadcasts(source: source, fixtures: fixtures)) ?? [:]
                    return (source.playlistID, values)
                }
            }
            for _ in 0 ..< 4 {
                if let source = iterator.next() { submit(source) }
            }
            var result: [UUID: [String: LumeSportsBroadcast]] = [:]
            for await (id, values) in group {
                if !values.isEmpty { result[id] = values }
                if !Task.isCancelled, let source = iterator.next() { submit(source) }
            }
            return result
        }
    }

    /// Per-fixture keys preserve cache reuse between differently sized surfaces.
    /// A pending result becoming ready, expiring, or changing evidence cannot
    /// be hidden behind the resolver's ten-minute local cache.
    static func proxyCacheKeys(_ broadcasts: [UUID: [String: LumeSportsBroadcast]], fixtures: [SportsFixture]) -> [String: Int] {
        var keys: [String: Int] = [:]
        for fixture in fixtures {
            var values: [UUID: LumeSportsBroadcast] = [:]
            for (id, items) in broadcasts {
                if let item = items[fixture.id] { values[id] = item }
            }
            if !values.isEmpty { keys[fixture.id] = values.hashValue }
        }
        return keys
    }

    static func proxyPlan(
        fixture: SportsFixture, visible: [String: Channel], broadcasts: [UUID: [String: LumeSportsBroadcast]]
    ) -> ProxyPlan {
        var plan = ProxyPlan()
        for (playlistID, items) in broadcasts {
            guard let item = items[fixture.id], item.matches(fixture), item.truncated != true else { continue }
            for candidate in item.candidates ?? [] {
                let id = CatalogID.content(playlistID, kind: .live, key: candidate.streamID)
                guard candidate.streamID > 0, let channel = visible[id], channel.playlistID == playlistID,
                      candidate.name == channel.summary.name,
                      candidate.epgID == (channel.summary.epgChannelId ?? ""),
                      channel.categoryID == CatalogID.category(playlistID, type: "live", key: candidate.categoryID),
                      let evidence = candidate.evidence.validated(kickoff: fixture.startDate) else { continue }
                let source: ResolvedChannelSource
                let score: Int
                switch evidence {
                case let .timed(value):
                    switch value.pairing {
                    case .explicit:
                        // A reviewed supplement backs a provider guide that didn't
                        // name the fixture; the provider's own headline ranks above it.
                        source = .epgTitleSubtitle
                        score = value.source == .provider ? 4 : 3
                    case .description:
                        source = .epgDescription
                        score = 1
                    }
                case .untimedChannelPairing:
                    source = .channelName
                    score = nameMatchScore
                    plan.suggestionIDs.insert(id)
                }
                // Free-form evidence may contain scores. Keep it out of every
                // detail/player surface, rather than relying on each to hide it.
                plan.channels.append(ResolvedChannel(
                    stream: channel.summary, playlistID: playlistID, matchedTitle: nil,
                    matchedStart: evidence.start, score: score,
                    source: source, isConfident: false
                ))
            }
        }
        return plan
    }

    static func mergeProxy(
        _ plan: ProxyPlan, local: [ResolvedChannel], fixture: SportsFixture, pickIndex: [String: String]
    ) -> [ResolvedChannel] {
        var byID = Dictionary(local.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var suggestions = plan.suggestionIDs
        var headlinePriorities = Dictionary(
            plan.channels.filter { $0.source == .epgTitleSubtitle }.map { ($0.id, $0.score) },
            uniquingKeysWith: max
        )
        // The device's guide merges provider and supplement listings, so a
        // local hit carries no provenance. One on the programme the proxy
        // judged (same start) is that same slot: the proxy found no provider
        // pairing there, so its priority stands. A local hit on a different
        // programme is independent evidence and keeps the ordinary priority.
        for proxied in plan.channels where headlinePriorities[proxied.id] != nil {
            guard let existing = byID[proxied.id], existing.source == .epgTitleSubtitle,
                  let localStart = existing.matchedStart, let proxyStart = proxied.matchedStart,
                  abs(localStart.timeIntervalSince(proxyStart)) >= 1 else { continue }
            headlinePriorities.removeValue(forKey: proxied.id)
        }
        for var candidate in plan.channels {
            let key = SportsChannelPicks.channelKey(epgChannelId: candidate.stream.epgChannelId, name: candidate.stream.name)
            if pickIndex[SportsChannelPicks.compositeKey(competitionKey: fixture.leagueId, channelKey: key)] != nil {
                candidate = ResolvedChannel(
                    stream: candidate.stream, playlistID: candidate.playlistID, matchedTitle: nil,
                    matchedStart: candidate.matchedStart, score: pickScoreBase + candidate.score,
                    source: .userPick, isConfident: false
                )
                suggestions.remove(candidate.id)
            }
            if let existing = byID[candidate.id], existing.source.rank <= candidate.source.rank {
                // A local match clears the proxy-only suggestion guard, but
                // confidence is still recomputed across all merged candidates.
                suggestions.remove(candidate.id)
                continue
            }
            byID[candidate.id] = candidate
        }
        return ranked(Array(byID.values), kickoff: fixture.headlineDate,
                      automaticExcludedIDs: suggestions, headlinePriorities: headlinePriorities)
    }
}
