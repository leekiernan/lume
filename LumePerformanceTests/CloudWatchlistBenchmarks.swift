import Foundation
@testable import Lume
import SQLite3
import SwiftData
import XCTest

/// The two sparse reads shared by reconciliation and profile switching. Each
/// measurement reopens an enriched SQLite catalogue to clear Core Data's row
/// cache, not the OS filesystem cache. Compare on the same simulator; these
/// timings do not stand in for Apple TV flash or end-to-end switch latency.
final class CloudWatchlistBenchmarks: XCTestCase {
    private let titleCount = 40000
    private let watchlistStride = 1000

    @MainActor
    func testOrderedMovies() throws {
        try measureWatchlist(Movie.self, descriptor: CloudWatchlistQuery.movies)
    }

    @MainActor
    func testUnorderedMovies() throws {
        try measureWatchlist(Movie.self, descriptor: FetchDescriptor(predicate: #Predicate { $0.addedToWatchlistDate != nil }))
    }

    @MainActor
    func testOrderedSeries() throws {
        try measureWatchlist(Series.self, descriptor: CloudWatchlistQuery.series)
    }

    @MainActor
    func testUnorderedSeries() throws {
        try measureWatchlist(Series.self, descriptor: FetchDescriptor(predicate: #Predicate { $0.addedToWatchlistDate != nil }))
    }

    /// Small, untimed production-model probe, also usable with SQLDebug launch
    /// arguments to verify the emitted SELECTs independently of the plan SQL.
    @MainActor
    func testProductionWatchlistPlans() throws {
        let store = try PerfStore.makeOnDiskContainer()
        defer { PerfStore.destroy(directory: store.directory) }
        let context = ModelContext(store.container)
        let date = Date(timeIntervalSinceReferenceDate: -1)
        let movie = Movie(id: "probe-movie", streamId: 1, name: "Synthetic movie")
        movie.addedToWatchlistDate = date
        let series = Series(id: "probe-series", seriesId: 1, name: "Synthetic series")
        series.addedToWatchlistDate = date
        context.insert(movie)
        context.insert(series)
        try context.save()
        let cold = ModelContext(store.container)
        XCTAssertEqual(try cold.fetch(CloudWatchlistQuery.movies).map(\.id), [movie.id])
        XCTAssertEqual(try cold.fetch(CloudWatchlistQuery.series).map(\.id), [series.id])
        try assertPlans(at: store.directory.appendingPathComponent("perf.store"), model: "Movie")
        try assertPlans(at: store.directory.appendingPathComponent("perf.store"), model: "Series")
    }

    @MainActor
    private func measureWatchlist<Model: PersistentModel>(_ model: Model.Type, descriptor: FetchDescriptor<Model>) throws {
        let store = try PerfStore.makeOnDiskContainer()
        defer { PerfStore.destroy(directory: store.directory) }
        let isMovie = model == Movie.self
        try seed(in: store.container, movies: isMovie)
        let url = store.directory.appendingPathComponent("perf.store")
        try assertPlans(at: url, model: isMovie ? "Movie" : "Series")
        let options = XCTMeasureOptions()
        options.iterationCount = 5
        options.invocationOptions = [.manuallyStart, .manuallyStop]
        measure(metrics: [XCTClockMetric()], options: options) {
            do {
                let config = ModelConfiguration(schema: PerfStore.catalogSchema, url: url, cloudKitDatabase: .none)
                let container = try ModelContainer(for: PerfStore.catalogSchema, configurations: config)
                let context = ModelContext(container)
                startMeasuring()
                let rows = try context.fetch(descriptor)
                stopMeasuring()
                XCTAssertEqual(rows.count, titleCount / watchlistStride)
            } catch {
                XCTFail("Watchlist read failed: \(error)")
            }
        }
    }

    private func seed(in container: ModelContainer, movies: Bool) throws {
        let plot = String(repeating: "Synthetic overview. ", count: 128)
        let payload = Data(repeating: 42, count: 2048)
        for start in stride(from: 0, to: titleCount, by: 500) {
            try autoreleasepool {
                let context = ModelContext(container)
                context.autosaveEnabled = false
                for index in start ..< min(start + 500, titleCount) {
                    let date = index.isMultiple(of: watchlistStride) ? Date(timeIntervalSinceReferenceDate: Double(index)) : nil
                    if movies {
                        let movie = Movie(id: "movie-\(index)", streamId: index, name: "Synthetic movie \(index)")
                        movie.plot = plot
                        movie.embeddingData = payload
                        movie.addedToWatchlistDate = date
                        context.insert(movie)
                    } else {
                        let series = Series(id: "series-\(index)", seriesId: index, name: "Synthetic series \(index)")
                        series.plot = plot
                        series.embeddingData = payload
                        series.addedToWatchlistDate = date
                        context.insert(series)
                    }
                }
                try context.save()
            }
        }
    }

    private func assertPlans(at url: URL, model: String) throws {
        var handle: OpaquePointer?
        let result = sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READONLY, nil)
        guard result == SQLITE_OK, let database = handle else {
            if let handle { sqlite3_close(handle) }
            throw CocoaError(.fileReadUnknown)
        }
        defer { sqlite3_close(database) }
        let table = "Z\(model.uppercased())"
        // A narrow SELECT could hide the problem by using a covering index.
        let base = "SELECT * FROM \(table) WHERE ZADDEDTOWATCHLISTDATE IS NOT NULL"
        for ordered in [false, true] {
            let sql = base + (ordered ? " ORDER BY ZADDEDTOWATCHLISTDATE" : "")
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(database, "EXPLAIN QUERY PLAN " + sql, -1, &statement, nil) == SQLITE_OK,
                  let statement else { throw CocoaError(.fileReadUnknown) }
            defer { sqlite3_finalize(statement) }
            var plan: [String] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                plan.append(String(cString: sqlite3_column_text(statement, 3)))
            }
            let message = "\(model) \(ordered ? "ordered" : "unordered"): \(plan)"
            print("CLOUD_WATCHLIST_PLAN \(message)")
            if ordered {
                XCTAssertTrue(plan.contains { $0.contains("SEARCH") && $0.contains("SwiftDataIndexOnBinaryaddedToWatchlistDate") }, message)
                XCTAssertFalse(plan.contains { $0.contains("SCAN") || $0.contains("TEMP B-TREE") }, message)
            }
        }
    }
}
