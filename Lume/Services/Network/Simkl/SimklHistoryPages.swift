import Foundation
import SwiftData

nonisolated enum SimklHistoryPage {
    case movies([SimklWatchedMovie])
    case shows([SimklWatchedShow])

    static func plan(_ items: SimklAllItems) -> [Self] {
        let movies = TrackerImportPages.groups(items.movies, maximumKeys: 100, key: { $0.movie.ids.tmdb }).map(Self.movies)
        let shows = TrackerImportPages.groups(items.shows, maximumKeys: 10, key: { $0.show.ids.tmdb }).map(Self.shows)
        let pages = movies + shows
        return pages.isEmpty ? [.movies([])] : pages
    }

    func apply(in context: ModelContext, scope: TrackerScope) -> SimklImportSummary {
        switch self {
        case let .movies(items): SimklWatchedImporter.apply(movies: items, shows: [], in: context, pendingScope: scope)
        case let .shows(items): SimklWatchedImporter.apply(movies: [], shows: items, in: context, pendingScope: scope)
        }
    }
}
