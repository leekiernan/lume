import Foundation

/// Optional evidence, not viewing permission. Only validated, fresh items reach
/// the resolver, which maps stream IDs inside their originating playlist.
nonisolated struct LumeSportsBroadcast: Decodable, Hashable {
    let eventID: String
    let status: String
    let fixture: LumeSportsFixture?
    let candidates: [LumeSportsCandidate]?
    let truncated: Bool?

    enum CodingKeys: String, CodingKey {
        case eventID = "event_id"
        case status, fixture, candidates, truncated
    }

    func matches(_ local: SportsFixture) -> Bool {
        guard status == "ready", let fixture, let candidates, candidates.count <= 256,
              fixture.source == "espn", fixture.competition == local.proxyCompetition,
              fixture.eventID == eventID, eventID == local.eventId,
              abs(fixture.start.timeIntervalSince(local.startDate)) < 1,
              fixture.home.id == local.home?.team.teamId, fixture.away.id == local.away?.team.teamId else { return false }
        return true
    }
}

nonisolated struct LumeSportsFixture: Decodable, Hashable {
    let source: String
    let competition: String
    let eventID: String
    let start: Date
    let home: LumeSportsTeam
    let away: LumeSportsTeam

    enum CodingKeys: String, CodingKey {
        case eventID = "event_id"
        case source, competition, start, home, away
    }
}

nonisolated struct LumeSportsTeam: Decodable, Hashable {
    let id: String
}

nonisolated struct LumeSportsCandidate: Decodable, Hashable {
    let streamID: Int
    let categoryID: String
    let epgID: String
    let name: String
    let evidence: LumeSportsEvidence

    enum CodingKeys: String, CodingKey {
        case streamID = "stream_id"
        case categoryID = "category_id"
        case epgID = "epg_id"
        case name, evidence
    }
}

nonisolated struct LumeSportsEvidence: Decodable, Hashable {
    let source: String
    let field: String
    let text: String
    let strength: String
    let classification: String
    let programmeID: String?
    let start: Date?
    let stop: Date?

    enum CodingKeys: String, CodingKey {
        case programmeID = "programme_id"
        case source, field, text, strength, classification, start, stop
    }

    func isValid(kickoff: Date) -> Bool {
        guard !text.isEmpty, text.count <= 4096,
              ["live", "unknown"].contains(classification) else { return false }
        if strength == "untimed_channel_pairing" {
            return source == "provider_channel" && field == "name" && start == nil && stop == nil && programmeID == nil
        }
        guard source == "provider" || source.hasPrefix("supplement:"),
              (strength == "explicit_pairing" && ["title", "subtitle"].contains(field))
              || (strength == "description_pairing" && field == "description"),
              let programmeID, !programmeID.isEmpty, let start, let stop,
              start >= kickoff.addingTimeInterval(-SportsMatcher.leadTime),
              start <= kickoff.addingTimeInterval(SportsMatcher.lateStart), stop > kickoff, stop > start else { return false }
        return true
    }
}

nonisolated struct LumeSportsBatch: Decodable {
    let version: Int
    let matcherVersion: Int
    let source: String
    let competition: String
    let status: String
    let verifiedAt: Date?
    let expiresAt: Date?
    let from: Date?
    let until: Date?
    let items: [Item]

    /// One malformed fixture cannot discard the other titles in a batch.
    struct Item: Decodable {
        let value: LumeSportsBroadcast?

        init(from decoder: Decoder) throws {
            value = try? LumeSportsBroadcast(from: decoder)
        }
    }

    enum CodingKeys: String, CodingKey {
        case version = "v"
        case matcherVersion = "matcher_v"
        case verifiedAt = "verified_at"
        case expiresAt = "expires_at"
        case until = "to"
        case source, competition, status, from, items
    }

    func broadcasts(for fixtures: [SportsFixture], competition: String, now: Date) -> [String: LumeSportsBroadcast] {
        guard version == 1, matcherVersion == 3, source == "espn", self.competition == competition,
              status == "ready", let verifiedAt, let expiresAt, let from, let until,
              verifiedAt <= now, now < expiresAt, expiresAt > verifiedAt,
              expiresAt.timeIntervalSince(verifiedAt) <= 24 * 3600, from < until, items.count <= 50 else { return [:] }
        let values = items.compactMap(\.value)
        let groups = Dictionary(grouping: values, by: \.eventID)
        var result: [String: LumeSportsBroadcast] = [:]
        for fixture in fixtures where fixture.startDate >= from && fixture.startDate < until {
            guard let group = groups[fixture.eventId], group.count == 1, let item = group.first,
                  item.matches(fixture) else { continue }
            result[fixture.id] = item
        }
        return result
    }

    static func decode(_ data: Data) -> Self? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let value = try decoder.singleValueContainer().decode(String.self)
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = formatter.date(from: value) { return date }
            formatter.formatOptions = [.withInternetDateTime]
            guard let date = formatter.date(from: value) else {
                throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Invalid sports timestamp"))
            }
            return date
        }
        return try? decoder.decode(Self.self, from: data)
    }
}

nonisolated extension SportsFixture {
    var proxyCompetition: String? {
        guard leagueId.hasPrefix("espn:soccer/"), hasTeams, sessionKind == nil,
              !eventId.isEmpty, eventId.count <= 64, eventId.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }) else { return nil }
        return String(leagueId.dropFirst("espn:".count))
    }
}

nonisolated extension LumeProxySource {
    func sportsURL(competition: String, ids: [String]) -> URL? {
        guard var components = URLComponents(url: capabilitiesURL, resolvingAgainstBaseURL: false),
              components.percentEncodedPath.hasSuffix("/capabilities") else { return nil }
        components.percentEncodedPath.removeLast("capabilities".count)
        components.percentEncodedPath += "sports/broadcasts"
        components.queryItems = (components.queryItems ?? []) + [
            URLQueryItem(name: "competition", value: competition),
            URLQueryItem(name: "ids", value: ids.joined(separator: ","))
        ]
        return components.url
    }
}
