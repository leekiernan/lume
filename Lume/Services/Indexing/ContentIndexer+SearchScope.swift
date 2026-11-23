//
//  ContentIndexer+SearchScope.swift
//  Lume
//
//  The store counts behind `TMDBSearchScope`: how many of a category's and a
//  playlist's titles carry a TMDB id. Counted with `fetchCount` (both columns
//  are indexed) and cached briefly, since every 50-title chunk asks again.
//

import Foundation
import SwiftData

extension ContentIndexer {
    private static let searchScopeLifetime: TimeInterval = 10 * 60

    /// Whether a title without a TMDB id should be searched for one.
    func searchesTMDB<Model: PersistentModel>(_: Model.Type, id: String, categoryID: String?, in context: ModelContext) throws -> Bool {
        // Ids are "<playlist UUID>-…"; one that isn't is searched as before.
        let playlistPrefix = RelatedTitlesResolver.playlistPrefix(of: id)
        guard !playlistPrefix.isEmpty else { return true }
        let isMovie = Model.self == Movie.self
        let kind = isMovie ? "movie" : "series"
        let playlist = try counts("\(kind)|playlist|\(playlistPrefix)") {
            try isMovie ? Self.movieCounts(prefix: playlistPrefix, in: context) : Self.seriesCounts(prefix: playlistPrefix, in: context)
        }
        guard let categoryID else { return true }
        let category = try counts("\(kind)|category|\(categoryID)") {
            try isMovie ? Self.movieCounts(category: categoryID, in: context) : Self.seriesCounts(category: categoryID, in: context)
        }
        return TMDBSearchScope.searches(category: category, playlist: playlist)
    }

    private func counts(_ key: String, now: Date = .now, count: () throws -> TMDBSearchScope.Counts) rethrows -> TMDBSearchScope.Counts {
        if let cached = searchScopeCounts[key], now.timeIntervalSince(cached.at) < Self.searchScopeLifetime {
            return cached.counts
        }
        let fresh = try count()
        searchScopeCounts[key] = (fresh, now)
        return fresh
    }

    private static func movieCounts(prefix: String, in context: ModelContext) throws -> TMDBSearchScope.Counts {
        try TMDBSearchScope.Counts(
            total: context.fetchCount(FetchDescriptor<Movie>(predicate: #Predicate { $0.id.starts(with: prefix) })),
            withID: context.fetchCount(FetchDescriptor<Movie>(predicate: #Predicate { $0.id.starts(with: prefix) && $0.tmdbId != nil }))
        )
    }

    private static func movieCounts(category: String, in context: ModelContext) throws -> TMDBSearchScope.Counts {
        try TMDBSearchScope.Counts(
            total: context.fetchCount(FetchDescriptor<Movie>(predicate: #Predicate { $0.categoryId == category })),
            withID: context.fetchCount(FetchDescriptor<Movie>(predicate: #Predicate { $0.categoryId == category && $0.tmdbId != nil }))
        )
    }

    private static func seriesCounts(prefix: String, in context: ModelContext) throws -> TMDBSearchScope.Counts {
        try TMDBSearchScope.Counts(
            total: context.fetchCount(FetchDescriptor<Series>(predicate: #Predicate { $0.id.starts(with: prefix) })),
            withID: context.fetchCount(FetchDescriptor<Series>(predicate: #Predicate { $0.id.starts(with: prefix) && $0.tmdbId != nil }))
        )
    }

    private static func seriesCounts(category: String, in context: ModelContext) throws -> TMDBSearchScope.Counts {
        try TMDBSearchScope.Counts(
            total: context.fetchCount(FetchDescriptor<Series>(predicate: #Predicate { $0.categoryId == category })),
            withID: context.fetchCount(FetchDescriptor<Series>(predicate: #Predicate { $0.categoryId == category && $0.tmdbId != nil }))
        )
    }
}
