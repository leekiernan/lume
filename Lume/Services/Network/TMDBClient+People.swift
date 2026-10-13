//
//  TMDBClient+People.swift
//  Lume
//
//  A person's acting credits, for the filmography a cast card opens. One
//  request covers every film and series, however low the billing: the
//  catalogue only stores the top-billed cast of titles someone has opened, so
//  it can't answer "what else is this actor in" on its own.
//

import Foundation

extension TMDBClient {
    /// The titles `personID` acted in, newest first, as list entries the
    /// collection resolver matches against the catalogue.
    func personCredits(_ personID: Int) async throws -> [HomeListEntry] {
        let response: TMDBPersonCredits = try await get("/person/\(personID)/combined_credits")
        return TMDBPersonCredits.entries(from: response.cast)
    }
}

nonisolated struct TMDBPersonCredits: Decodable {
    let cast: [TMDBPersonCredit]

    /// TMDB's Talk and News TV genres: guest spots on chat and news shows
    /// aren't roles, and they'd fill a busy actor's page.
    static let appearanceGenres: Set<Int> = [10767, 10763]

    /// Acting credits only, each title once, newest first (undated last, then
    /// the more popular first). TV credits playing themselves — award shows,
    /// specials — are appearances too; a film's "Himself" (a documentary
    /// about them) stays.
    static func entries(from credits: [TMDBPersonCredit]) -> [HomeListEntry] {
        struct Identity: Hashable {
            let id: Int
            let type: HomeListEntry.MediaType
        }
        var seen: Set<Identity> = []
        var kept: [(entry: HomeListEntry, date: String, popularity: Double)] = []
        for credit in credits {
            let type: HomeListEntry.MediaType
            switch credit.mediaType {
            case "movie": type = .movie
            case "tv": type = .series
            default: continue
            }
            if type == .series {
                if !appearanceGenres.isDisjoint(with: credit.genreIds ?? []) || playsSelf(credit.character) { continue }
            }
            guard seen.insert(Identity(id: credit.id, type: type)).inserted else { continue }
            let date = (type == .movie ? credit.releaseDate : credit.firstAirDate) ?? ""
            let title = credit.title ?? credit.name ?? ""
            kept.append((HomeListEntry(tmdbId: credit.id, mediaType: type, title: title), date, credit.popularity ?? 0))
        }
        return kept.sorted { lhs, rhs in
            if lhs.date.isEmpty != rhs.date.isEmpty { return !lhs.date.isEmpty }
            if lhs.date != rhs.date { return lhs.date > rhs.date }
            return lhs.popularity > rhs.popularity
        }.map(\.entry)
    }

    private static func playsSelf(_ character: String?) -> Bool {
        guard let first = character?.split(whereSeparator: { !$0.isLetter }).first?.lowercased() else { return false }
        return ["self", "himself", "herself", "themselves", "themself"].contains(first)
    }
}

/// One acting credit in a person's combined credits.
nonisolated struct TMDBPersonCredit: Decodable, Equatable {
    let id: Int
    let mediaType: String?
    let title: String?
    let name: String?
    let releaseDate: String?
    let firstAirDate: String?
    let character: String?
    let genreIds: [Int]?
    let popularity: Double?

    enum CodingKeys: String, CodingKey {
        case id, title, name, character, popularity
        case mediaType = "media_type"
        case releaseDate = "release_date"
        case firstAirDate = "first_air_date"
        case genreIds = "genre_ids"
    }
}
