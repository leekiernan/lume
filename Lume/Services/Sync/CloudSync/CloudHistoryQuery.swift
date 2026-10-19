import Foundation
import SwiftData

/// Read every watched series, not a display preview. Like the watchlist reads
/// (`CloudWatchlistQuery`), an unordered `IS NOT NULL` scans the wide series
/// table despite the date index; ordering by that same date selects the index.
/// The reconciler keys rows by content ID, so the order changes nothing it
/// aggregates, and there is no limit: every history entry is still read.
nonisolated enum CloudHistoryQuery {
    static var series: FetchDescriptor<Series> {
        FetchDescriptor(
            predicate: #Predicate { $0.lastWatchedDate != nil },
            sortBy: [SortDescriptor(\.lastWatchedDate)]
        )
    }
}
