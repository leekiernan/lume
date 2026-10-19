import OSLog
import SwiftData

/// Attribution only: keeps the existing reactive query, ordering and limit.
/// The device trace showed expensive reads inside SwiftUI's focus/layout pass;
/// direct ModelContext benchmarks cannot identify which @Query rail it was.
enum LibraryCollectionRead {
    static func measure<Model: PersistentModel>(
        _ kind: LibraryCollection.Kind,
        media: HomeListEntry.MediaType,
        read: () -> [Model]
    ) -> [Model] {
        let mark = signpost(kind, media: media)
        let started = ContinuousClock.now
        let rows = Perf.measure(mark, read)
        let elapsed = started.duration(to: .now)
        if elapsed >= .milliseconds(100) {
            Logger.home.notice("Slow library read: \(media.rawValue, privacy: .public).\(kind.rawValue, privacy: .public), \(rows.count) rows, \(elapsed.logSeconds, privacy: .public)")
        }
        return rows
    }

    static func signpost(_ kind: LibraryCollection.Kind, media: HomeListEntry.MediaType) -> PerfSignpost {
        switch (media, kind) {
        case (.movie, .continueWatching): .libraryMovieContinueRead
        case (.movie, .recentlyWatched): .libraryMovieWatchedRead
        case (.movie, .favorites): .libraryMovieFavoritesRead
        case (.movie, .recentlyAdded): .libraryMovieAddedRead
        case (.series, .continueWatching): .librarySeriesContinueRead
        case (.series, .recentlyWatched): .librarySeriesWatchedRead
        case (.series, .favorites): .librarySeriesFavoritesRead
        case (.series, .recentlyAdded): .librarySeriesAddedRead
        }
    }
}
