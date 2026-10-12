import Foundation
import OSLog
import SwiftData

nonisolated extension SportsChannelResolver {
    struct ProxyPlan {
        var channels: [ResolvedChannel] = []
        var coveredPlaylists: Set<UUID> = []
        var suggestionIDs: Set<String> = []
    }

    struct ProxyLocalScope {
        let fixtures: [SportsFixture]
        let channelIDs: Set<String>
        let playlists: Set<UUID>
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
        let covered = plans.values.count(where: { !$0.coveredPlaylists.isEmpty })
        let offered = plans.values.reduce(0) { $0 + $1.channels.count }
        Logger.network.info("Sports proxy: \(covered) of \(fixtures.count) fixtures have timed matches; \(offered) visible candidates")
        return plans
    }

    static func proxyLocalScope(fixtures: [SportsFixture], channels: [Channel], plans: [String: ProxyPlan]) -> ProxyLocalScope {
        let playlists = Set(channels.map(\.playlistID))
        let localFixtures = fixtures.filter { plans[$0.id]?.coveredPlaylists.isSuperset(of: playlists) != true }
        var counts: [UUID: Int] = [:]
        for plan in plans.values {
            for playlistID in plan.coveredPlaylists {
                counts[playlistID, default: 0] += 1
            }
        }
        // O(channels + fixtures * playlists), not O(channels * fixtures).
        let needsLocal = playlists.filter { counts[$0, default: 0] < fixtures.count }
        let ids = channels.compactMap { channel -> String? in
            guard needsLocal.contains(channel.playlistID), let id = channel.summary.epgChannelId, !id.isEmpty else { return nil }
            return id
        }
        return ProxyLocalScope(fixtures: localFixtures, channelIDs: Set(ids), playlists: needsLocal)
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
            var timed = false
            for candidate in item.candidates ?? [] {
                let id = CatalogID.content(playlistID, kind: .live, key: candidate.streamID)
                guard candidate.streamID > 0, let channel = visible[id], channel.playlistID == playlistID,
                      candidate.name == channel.summary.name,
                      candidate.epgID == (channel.summary.epgChannelId ?? ""),
                      channel.categoryID == CatalogID.category(playlistID, type: "live", key: candidate.categoryID),
                      candidate.evidence.isValid(kickoff: fixture.startDate) else { continue }
                let evidence = candidate.evidence
                let source: ResolvedChannelSource
                switch evidence.strength {
                case "explicit_pairing": source = .epgTitleSubtitle
                case "description_pairing": source = .epgDescription
                default:
                    source = .channelName
                    plan.suggestionIDs.insert(id)
                }
                timed = timed || evidence.start != nil
                // Free-form evidence may contain scores. Keep it out of every
                // detail/player surface, rather than relying on each to hide it.
                plan.channels.append(ResolvedChannel(
                    stream: channel.summary, playlistID: playlistID, matchedTitle: nil,
                    matchedStart: evidence.start, score: source == .epgTitleSubtitle ? 4 : 1,
                    source: source, isConfident: false
                ))
            }
            // Empty/post-filter-empty and untimed-only answers are not proof
            // of absence: run the ordinary matcher for this playlist instead.
            if timed { plan.coveredPlaylists.insert(playlistID) }
        }
        return plan
    }

    static func mergeProxy(
        _ plan: ProxyPlan, local: [ResolvedChannel], fixture: SportsFixture, pickIndex: [String: String]
    ) -> [ResolvedChannel] {
        var byID = Dictionary(local.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var suggestions = plan.suggestionIDs
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
                // Repeating the same untimed name in the local matcher is not
                // independent timed evidence. A guide hit or explicit pick is.
                if existing.source != .channelName { suggestions.remove(candidate.id) }
                continue
            }
            byID[candidate.id] = candidate
        }
        return ranked(Array(byID.values), kickoff: fixture.headlineDate, automaticExcludedIDs: suggestions)
    }
}
