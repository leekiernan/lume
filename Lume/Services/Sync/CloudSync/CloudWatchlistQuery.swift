import Foundation
import SwiftData

/// Read every watchlisted title, not a display preview. On a wide catalogue,
/// SQLite can scan the table for an unordered `IS NOT NULL` despite the date
/// index. Ordering by that same date selects the index; aggregation is keyed
/// by content ID, so this does not change profile state or visible ordering.
nonisolated enum CloudWatchlistQuery {
    static var movies: FetchDescriptor<Movie> {
        FetchDescriptor(
            predicate: #Predicate { $0.addedToWatchlistDate != nil },
            sortBy: [SortDescriptor(\.addedToWatchlistDate)]
        )
    }

    static var series: FetchDescriptor<Series> {
        FetchDescriptor(
            predicate: #Predicate { $0.addedToWatchlistDate != nil },
            sortBy: [SortDescriptor(\.addedToWatchlistDate)]
        )
    }
}
