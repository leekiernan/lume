import Foundation

/// Deliberately excludes scores, game status, descriptions and broadcaster text.
nonisolated struct LumeSportsArtwork: Decodable, Equatable {
    let eventID: String
    let status: String
    let fixture: LumeSportsFixture
    let artwork: Images?

    struct Images: Decodable, Equatable {
        let thumb: URL?
        let fanart: URL?
        let poster: URL?

        func url(portrait: Bool, excluding failed: Set<URL> = []) -> URL? {
            let candidates = portrait ? [poster, fanart, thumb] : [fanart, thumb]
            return candidates.compactMap(Self.allowed).first { !failed.contains($0) }
        }

        /// Public image locations only: never turn the proxy into an arbitrary
        /// URL launcher or carry account credentials into an image request.
        static func allowed(_ url: URL?) -> URL? {
            guard let url, url.absoluteString.utf8.count <= 2048,
                  let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
                  parts.scheme == "https", parts.user == nil, parts.password == nil,
                  parts.port == nil, parts.fragment == nil,
                  !parts.path.contains(".."), !parts.percentEncodedPath.contains("%") else { return nil }
            switch parts.host?.lowercased() {
            case "sportarr.net":
                let query = parts.queryItems ?? []
                guard parts.path.hasPrefix("/static/images/event/"),
                      query.count <= 1,
                      query.allSatisfy({ item in
                          guard item.name == "v", let value = item.value, !value.isEmpty, value.count <= 80 else { return false }
                          return value.utf8.allSatisfy { (48 ... 57).contains($0) || (65 ... 90).contains($0) || (97 ... 122).contains($0) || $0 == 45 || $0 == 95 }
                      }) else { return nil }
            case "www.thesportsdb.com", "r2.thesportsdb.com":
                guard parts.path.hasPrefix("/images/media/event/"), parts.query == nil else { return nil }
            default: return nil
            }
            return url
        }
    }

    enum CodingKeys: String, CodingKey {
        case eventID = "event_id"
        case status, fixture, artwork
    }
}

nonisolated struct LumeSportsArtworkPublication: Equatable {
    let value: LumeSportsArtwork
    let expiresAt: Date
}

nonisolated struct LumeSportsArtworkBatch: Decodable {
    let version: Int
    let source: String
    let artworkSource: String
    let competition: String
    let status: String
    let matcherVersion: Int
    let verifiedAt: Date
    let expiresAt: Date
    let from: Date
    let until: Date
    let items: [Item]

    struct Item: Decodable {
        let eventID: String?
        let value: LumeSportsArtwork?
        init(from decoder: Decoder) throws {
            let container = try? decoder.container(keyedBy: LumeSportsArtwork.CodingKeys.self)
            eventID = try? container?.decode(String.self, forKey: .eventID)
            value = try? LumeSportsArtwork(from: decoder)
        }
    }

    enum CodingKeys: String, CodingKey {
        case version = "v"
        case matcherVersion = "matcher_v"
        case artworkSource = "artwork_source"
        case until = "to"
        case verifiedAt = "verified_at"
        case expiresAt = "expires_at"
        case source, competition, status, from, items
    }

    func validated(for fixtures: [SportsFixture], competition: String, now: Date) -> [String: LumeSportsArtworkPublication] {
        guard version == 1, matcherVersion == 1, source == "espn", artworkSource == "sportarr", self.competition == competition, status == "ready",
              verifiedAt <= now, now < expiresAt, expiresAt > verifiedAt,
              expiresAt.timeIntervalSince(verifiedAt) <= 86400, from < until, items.count <= 50 else { return [:] }
        let groups = Dictionary(grouping: items, by: \.eventID)
        var result: [String: LumeSportsArtworkPublication] = [:]
        for fixture in fixtures where fixture.startDate >= from && fixture.startDate < until {
            guard let group = groups[fixture.eventId], group.count == 1, let item = group.first?.value,
                  ["matched", "unmatched", "ambiguous"].contains(item.status),
                  item.eventID == item.fixture.eventID, item.fixture.matches(fixture, competition: fixture.artworkCompetition) else { continue }
            result[fixture.id] = LumeSportsArtworkPublication(value: item, expiresAt: expiresAt)
        }
        return result
    }
}

nonisolated extension SportsFixture {
    /// Artwork is independent of football broadcast matching. A proxy must
    /// still advertise the exact competition and echo the current fixture.
    var artworkCompetition: String? {
        guard let competition = espnTeamCompetition,
              let sport = competition.split(separator: "/").first,
              ["soccer", "football", "basketball", "hockey"].contains(String(sport)) else { return nil }
        return competition
    }
}

nonisolated extension LumeProxySource {
    func sportsArtworkURL(competition: String, ids: [String]) -> URL? {
        guard let url = sportsURL(competition: competition, ids: ids),
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        components.percentEncodedPath.removeLast("broadcasts".count)
        components.percentEncodedPath += "artwork"
        return components.url
    }
}
