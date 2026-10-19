import Foundation
@testable import Lume
import SQLite3
import SwiftData
import SwiftUI
import XCTest
#if canImport(UIKit)
    import UIKit
#else
    import AppKit
#endif

/// Three reads that scanned wide catalogue rows on device: the reconciler's
/// series history, the Series tab's watch rows, and the indexer's indexed-title
/// count. Each pair measures the previous shape against the shipping one on the
/// same enriched on-disk store; "before" drops the index the change added. Each
/// iteration reopens the container, clearing Core Data's row cache but not the
/// OS filesystem cache, so these compare shapes, not Apple TV flash latency.
final class CatalogStateReadBenchmarks: XCTestCase {
    private let titleCount = 40000
    /// One series in a hundred has watch history.
    private let watchedStride = 100
    /// Movies indexed: nine in ten.
    private let unindexedStride = 10
    /// Prime, so the watched and unindexed strides spread across categories
    /// rather than all landing in one (hidden) category.
    private let categoryCount = 97
    private let prefix = "playlist-"
    /// Ten categories hidden, as a household with restrictions.
    private var hidden: Set<String> {
        Set((0 ..< 10).map { "category-\($0)" })
    }

    // MARK: - 1. Reconciler series history

    @MainActor
    func testSeriesHistoryUnordered() throws {
        try measureRead(seed: .series) { context in
            try context.fetch(FetchDescriptor<Series>(predicate: #Predicate { $0.lastWatchedDate != nil })).count
        } expect: { $0 == self.titleCount / self.watchedStride }
    }

    @MainActor
    func testSeriesHistoryOrdered() throws {
        try measureRead(seed: .series) { context in
            try context.fetch(CloudHistoryQuery.series).count
        } expect: { $0 == self.titleCount / self.watchedStride }
    }

    // MARK: - 2. Series watch rows and Show All

    @MainActor
    func testSeriesRailBefore() throws {
        try measureRead(seed: .series, dropping: ["Z_Series_SwiftDataIndexOnBinarylastWatchedDateid"]) { context in
            try self.mountedCount(self.previousRailDescriptor(limit: collectionRowFetchLimit), in: context.container)
        } expect: { $0 == collectionRowFetchLimit }
    }

    @MainActor
    func testSeriesRailAfter() throws {
        try measureRead(seed: .series) { context in
            try self.mountedCount(
                SeriesCollectionQuery.rowDescriptor(for: .continueWatching, playlistPrefix: self.prefix, excludedCategoryIDs: self.hidden),
                in: context.container
            )
        } expect: { $0 == collectionRowFetchLimit }
    }

    @MainActor
    func testSeriesShowAllPageBefore() throws {
        try measureRead(seed: .series, dropping: ["Z_Series_SwiftDataIndexOnBinarylastWatchedDateid"]) { context in
            var descriptor = self.previousRailDescriptor(limit: 60)
            descriptor.fetchOffset = 60
            return try context.fetch(descriptor).count
        } expect: { $0 == 60 }
    }

    @MainActor
    func testSeriesShowAllPageAfter() throws {
        try measureRead(seed: .series) { context in
            try context.fetch(SeriesCollectionQuery.pageDescriptor(
                for: .continueWatching, playlistPrefix: self.prefix, excludedCategoryIDs: self.hidden, offset: 60, limit: 60
            )).count
        } expect: { $0 == 60 }
    }

    /// The new order returns the same rows; with no tied watch dates in the
    /// fixture, in the same order as the old descriptor.
    @MainActor
    func testSeriesRailResultsUnchanged() throws {
        let store = try PerfStore.makeOnDiskContainer()
        defer { PerfStore.destroy(directory: store.directory) }
        try seed(.series, in: store.container)
        let context = ModelContext(store.container)
        var old = previousRailDescriptor(limit: 1000)
        old.fetchLimit = nil
        let new = SeriesCollectionQuery.gridDescriptor(for: .continueWatching, playlistPrefix: prefix)
        var filtered = new
        filtered.predicate = old.predicate
        XCTAssertEqual(try context.fetch(old).map(\.id), try context.fetch(filtered).map(\.id))
    }

    // MARK: - 3. Indexer counts

    @MainActor
    func testIndexedMovieCountBefore() throws {
        try measureRead(seed: .movies, dropping: ["Z_Movie_SwiftDataIndexOnBinaryindexedAtcategoryId"]) { context in
            try context.fetchCount(FetchDescriptor<Movie>(predicate: ContentIndexer.indexedMoviePredicate(excluding: self.hidden)))
        } expect: { $0 == self.expectedIndexedVisibleMovies }
    }

    @MainActor
    func testIndexedMovieCountAfter() throws {
        try measureRead(seed: .movies) { context in
            try context.fetchCount(FetchDescriptor<Movie>(predicate: ContentIndexer.indexedMoviePredicate(excluding: self.hidden)))
        } expect: { $0 == self.expectedIndexedVisibleMovies }
    }

    private var expectedIndexedVisibleMovies: Int {
        (0 ..< titleCount).count { !$0.isMultiple(of: unindexedStride) && $0 % categoryCount >= 10 }
    }

    // MARK: - Harness

    private enum Seed { case series, movies }

    /// The Series watch rows' descriptor before this change: localized name and
    /// id tie-breaks after the watch date.
    private func previousRailDescriptor(limit: Int) -> FetchDescriptor<Series> {
        let excluded = Set(hidden.map(String?.some))
        let prefix = prefix
        var descriptor = FetchDescriptor<Series>(
            predicate: #Predicate {
                $0.lastWatchedDate != nil
                    && $0.id.starts(with: prefix)
                    && ($0.categoryId == nil || !excluded.contains($0.categoryId))
            },
            sortBy: [SortDescriptor(\.lastWatchedDate, order: .reverse), SortDescriptor(\.name), SortDescriptor(\.id)]
        )
        descriptor.fetchLimit = limit
        return descriptor
    }

    @MainActor
    private func measureRead(
        seed kind: Seed,
        dropping indexes: [String] = [],
        _ read: @escaping (ModelContext) throws -> Int,
        expect: @escaping (Int) -> Bool
    ) throws {
        let store = try PerfStore.makeOnDiskContainer()
        defer { PerfStore.destroy(directory: store.directory) }
        try seed(kind, in: store.container)
        let url = store.directory.appendingPathComponent("perf.store")
        try drop(indexes, at: url)
        let options = XCTMeasureOptions()
        options.iterationCount = 5
        options.invocationOptions = [.manuallyStart, .manuallyStop]
        measure(metrics: [XCTClockMetric()], options: options) {
            do {
                let config = ModelConfiguration(schema: PerfStore.catalogSchema, url: url, cloudKitDatabase: .none)
                let container = try ModelContainer(for: PerfStore.catalogSchema, configurations: config)
                let context = ModelContext(container)
                startMeasuring()
                let count = try read(context)
                stopMeasuring()
                XCTAssertTrue(expect(count), "unexpected result count \(count)")
            } catch {
                XCTFail("Read failed: \(error)")
            }
        }
    }

    /// A mounted @Query, which appends `Z_PK` to ORDER BY unlike a direct fetch.
    /// The row count comes from the view's own query result.
    @MainActor
    private func mountedCount(_ descriptor: FetchDescriptor<Series>, in container: ModelContainer) throws -> Int {
        let rows = RowCount()
        let view = MountedSeries(descriptor: descriptor, rows: rows).modelContainer(container)
        #if canImport(UIKit)
            let host = UIHostingController(rootView: view)
            _ = host.sizeThatFits(in: CGSize(width: 800, height: 600))
        #else
            let host = NSHostingView(rootView: view)
            host.frame = CGRect(x: 0, y: 0, width: 800, height: 600)
            host.layoutSubtreeIfNeeded()
        #endif
        return rows.value
    }

    private final class RowCount {
        var value = -1
    }

    private struct MountedSeries: View {
        @Query private var series: [Series]
        let rows: RowCount
        init(descriptor: FetchDescriptor<Series>, rows: RowCount) {
            _series = Query(descriptor)
            self.rows = rows
        }

        var body: some View {
            rows.value = series.count
            return Text(series.map(\.id).joined(separator: ","))
        }
    }

    private func seed(_ kind: Seed, in container: ModelContainer) throws {
        let plot = String(repeating: "Synthetic overview. ", count: 128)
        let payload = Data(repeating: 42, count: 2048)
        for start in stride(from: 0, to: titleCount, by: 500) {
            try autoreleasepool {
                let context = ModelContext(container)
                context.autosaveEnabled = false
                for index in start ..< min(start + 500, titleCount) {
                    let category = "category-\(index % categoryCount)"
                    switch kind {
                    case .series:
                        let series = Series(id: "\(prefix)series-\(index)", seriesId: index, name: "Synthetic series \(index)")
                        series.plot = plot
                        series.embeddingData = payload
                        series.categoryId = category
                        series.indexedAt = .now
                        if index.isMultiple(of: watchedStride) {
                            series.lastWatchedDate = Date(timeIntervalSinceReferenceDate: Double(index))
                        }
                        context.insert(series)
                    case .movies:
                        let movie = Movie(id: "\(prefix)movie-\(index)", streamId: index, name: "Synthetic movie \(index)")
                        movie.plot = plot
                        movie.categoryId = category
                        if !index.isMultiple(of: unindexedStride) {
                            movie.embeddingData = payload
                            movie.indexedAt = .now
                        }
                        context.insert(movie)
                    }
                }
                try context.save()
            }
        }
    }

    private func drop(_ indexes: [String], at url: URL) throws {
        guard !indexes.isEmpty else { return }
        var handle: OpaquePointer?
        guard sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK, let database = handle else {
            if let handle { sqlite3_close(handle) }
            throw CocoaError(.fileReadUnknown)
        }
        defer { sqlite3_close(database) }
        for name in indexes {
            XCTAssertEqual(sqlite3_exec(database, "DROP INDEX \(name)", nil, nil, nil), SQLITE_OK, name)
        }
    }
}
