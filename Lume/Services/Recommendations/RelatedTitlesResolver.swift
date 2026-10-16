import Foundation
import SwiftData

/// Keep TMDB namespaces and viewer restrictions through every catalog lookup.
enum RelatedTitlesResolver {
    static let similarLimit = 12

    static func playlistPrefix(of id: String) -> String {
        let head = String(id.prefix(36))
        guard UUID(uuidString: head) != nil else { return "" }
        return head + "-"
    }

    static func similar(to movie: Movie, restriction: ContentRestriction, in context: ModelContext) -> [HomeMediaItem] {
        let references = movie.similarTitleIds.compactMap { TMDBMovieID($0).map(TMDBTitleReference.movie) }
        return Array(resolve(references, scope: Scope(ownerID: movie.id, restriction: restriction), in: context).prefix(similarLimit))
    }

    static func similar(to series: Series, restriction: ContentRestriction, in context: ModelContext) -> [HomeMediaItem] {
        let references = series.similarTitleIds.compactMap { TMDBSeriesID($0).map(TMDBTitleReference.series) }
        return Array(resolve(references, scope: Scope(ownerID: series.id, restriction: restriction), in: context).prefix(similarLimit))
    }

    static func collectionParts(_ partIDs: [Int], of movie: Movie, restriction: ContentRestriction, in context: ModelContext) -> [HomeMediaItem] {
        resolve(partIDs.compactMap { TMDBMovieID($0).map(TMDBTitleReference.movie) },
                scope: Scope(ownerID: movie.id, restriction: restriction), in: context)
    }

    struct Scope {
        let ownerID: String
        let restriction: ContentRestriction
    }

    static func resolve(_ references: [TMDBTitleReference], scope: Scope, in context: ModelContext) -> [HomeMediaItem] {
        let movieIDs = Set(references.filter { $0.kind == .movie }.map { Optional($0.rawValue) })
        let seriesIDs = Set(references.filter { $0.kind == .series }.map { Optional($0.rawValue) })
        let candidates = movies(movieIDs, scope: scope, in: context) + series(seriesIDs, scope: scope, in: context)
        var items: [TMDBTitleReference: HomeMediaItem] = [:]
        for item in candidates {
            switch item {
            case let .movie(row):
                if let identity = row.metadataIdentity, items[identity] == nil { items[identity] = item }
            case let .series(row):
                if let identity = row.metadataIdentity, items[identity] == nil { items[identity] = item }
            case .live: break
            }
        }
        var seen = Set<TMDBTitleReference>()
        return references.compactMap { seen.insert($0).inserted ? items[$0] : nil }
    }

    private static func movies(_ ids: Set<Int?>, scope: Scope, in context: ModelContext) -> [HomeMediaItem] {
        guard !ids.isEmpty else { return [] }
        let prefix = playlistPrefix(of: scope.ownerID)
        let descriptor = FetchDescriptor<Movie>(predicate: #Predicate { ids.contains($0.tmdbId) && $0.id.starts(with: prefix) },
                                                sortBy: [SortDescriptor(\.id, comparator: .lexical)])
        return ((try? context.fetch(descriptor)) ?? []).filter {
            $0.id != scope.ownerID && !scope.restriction.hides(categoryID: $0.categoryId)
        }.map(HomeMediaItem.movie)
    }

    private static func series(_ ids: Set<Int?>, scope: Scope, in context: ModelContext) -> [HomeMediaItem] {
        guard !ids.isEmpty else { return [] }
        let prefix = playlistPrefix(of: scope.ownerID)
        let descriptor = FetchDescriptor<Series>(predicate: #Predicate { ids.contains($0.tmdbId) && $0.id.starts(with: prefix) },
                                                 sortBy: [SortDescriptor(\.id, comparator: .lexical)])
        return ((try? context.fetch(descriptor)) ?? []).filter {
            $0.id != scope.ownerID && !scope.restriction.hides(categoryID: $0.categoryId)
        }.map(HomeMediaItem.series)
    }
}
