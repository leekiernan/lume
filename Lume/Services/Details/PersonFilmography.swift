//
//  PersonFilmography.swift
//  Lume
//
//  What a cast card opens: the person's titles in the playlist the detail
//  page came from. TMDB's combined credits name every title; the collection
//  resolver keeps the ones the catalogue has, in the viewer's restrictions.
//
//  Credits are small (a few hundred ids at most) and the same people recur as
//  the viewer goes deeper — actor, film, co-star, film — so they're kept in
//  memory for the session, one request per person.
//

import Foundation
import SwiftData

/// A pushed person page. Carries what the header shows, so the page draws at
/// once, and the playlist its titles are matched in.
nonisolated struct PersonRoute: Hashable {
    let personID: Int
    let name: String
    let profilePath: String?
    /// `"<playlistUUID>-"`, or empty to match every playlist.
    let playlistPrefix: String
}

extension PersonRoute {
    /// The person on a title's cast card, matched in that title's playlist.
    init(member: CastMember) {
        let owner = member.movie?.id ?? member.series?.id ?? ""
        self.init(
            personID: member.tmdbPersonId, name: member.name, profilePath: member.profilePath,
            playlistPrefix: RelatedTitlesResolver.playlistPrefix(of: owner)
        )
    }
}

/// Session cache of TMDB credits by person, coalescing concurrent requests.
actor PersonCreditsStore {
    static let shared = PersonCreditsStore()

    private let fetch: @Sendable (Int) async throws -> [HomeListEntry]
    private let limit: Int
    private var cache: [Int: [HomeListEntry]] = [:]
    private var order: [Int] = []
    private var inFlight: [Int: Task<[HomeListEntry], Error>] = [:]

    init(limit: Int = 64, fetch: (@Sendable (Int) async throws -> [HomeListEntry])? = nil) {
        self.limit = limit
        self.fetch = fetch ?? {
            guard let id = TMDBPersonID($0) else { return [] }
            return try await TMDBClient.shared.personCredits(id)
        }
    }

    /// `nil` when TMDB is unavailable (no key, offline, an error); the caller
    /// falls back to the cast the catalogue already holds. Failures aren't
    /// cached, so the next visit tries again.
    func credits(for personID: Int) async -> [HomeListEntry]? {
        if let cached = cache[personID] {
            touch(personID)
            return cached
        }
        let task: Task<[HomeListEntry], Error>
        if let existing = inFlight[personID] {
            task = existing
        } else {
            let fetch = fetch
            task = Task { try await fetch(personID) }
            inFlight[personID] = task
        }
        let result = try? await task.value
        inFlight[personID] = nil
        guard let result else { return nil }
        cache[personID] = result
        touch(personID)
        while order.count > limit {
            cache[order.removeFirst()] = nil
        }
        return result
    }

    private func touch(_ personID: Int) {
        order.removeAll { $0 == personID }
        order.append(personID)
    }
}

enum PersonFilmography {
    /// Titles the catalogue already lists this person in — the cast stored
    /// for detail pages opened before. Only top-billed cast of opened titles,
    /// so a partial answer, used when TMDB can't give the whole one.
    static func localEntries(personID: Int, in context: ModelContext) -> [HomeListEntry] {
        let descriptor = FetchDescriptor<CastMember>(predicate: #Predicate { $0.tmdbPersonId == personID })
        let members = (try? context.fetch(descriptor)) ?? []
        return members.compactMap { member in
            if let movie = member.movie, let id = movie.tmdbId {
                return HomeListEntry(tmdbId: id, mediaType: .movie, title: movie.name)
            }
            if let series = member.series, let id = series.tmdbId {
                return HomeListEntry(tmdbId: id, mediaType: .series, title: series.name)
            }
            return nil
        }
    }
}
