import Foundation
import SwiftData

nonisolated enum TraktHistoryPage {
    case movies([TraktWatchedMovie])
    case shows([TraktWatchedShow])
    case paused([TraktPlaybackItem])

    static func plan(movies: [TraktWatchedMovie], shows: [TraktWatchedShow], paused: [TraktPlaybackItem]?) -> [Self] {
        let movies = TrackerImportPages.groups(movies, maximumKeys: 100, key: { $0.movie.ids.tmdb }).map(Self.movies)
        let shows = TrackerImportPages.groups(shows, maximumKeys: 10, key: { $0.show.ids.tmdb }).map(Self.shows)
        let paused = TrackerImportPages.groups(paused ?? [], maximumKeys: 10) { item -> String? in
            if let id = item.movie?.ids.tmdb { return "movie-\(id)" }
            return item.show?.ids.tmdb.map { "show-\($0)" }
        }.map(Self.paused)
        let pages = movies + shows + paused
        // Even an empty response must pass the account/profile gate.
        return pages.isEmpty ? [.movies([])] : pages
    }

    func apply(in context: ModelContext, scope: TrackerScope) -> TraktImportSummary {
        switch self {
        case let .movies(items): return TraktWatchedImporter.apply(movies: items, shows: [], in: context, pendingScope: scope)
        case let .shows(items): return TraktWatchedImporter.apply(movies: [], shows: items, in: context, pendingScope: scope)
        case let .paused(items):
            var summary = TraktImportSummary(inProgress: TraktPlaybackImporter.apply(items, in: context, pendingScope: scope))
            do { if context.hasChanges { try context.save() } } catch { summary.failed = true }
            return summary
        }
    }
}
