//
//  CatalogStateReadPlanTests.swift
//  LumeTests
//
//  Plans for three reads that scanned wide catalogue rows on device: the
//  reconciler's series history, the Series tab's watch rows and their Show
//  All grid, and the content indexer's indexed-title counts. Each SQL string
//  is the statement Core Data emitted for the shipping descriptor (captured
//  with `-com.apple.CoreData.SQLDebug 1`), reduced to `SELECT *` so a covering
//  index cannot hide a table read. The mounted row keeps the `Z_PK` term
//  @Query appends, which a direct fetch does not; that term is what tipped
//  the old three-key sort into a scan. Benchmarks: `CatalogStateReadBenchmarks`.
//

import Foundation
@testable import Lume
import SQLite3
import SwiftData
import Testing

@MainActor
struct CatalogStateReadPlanTests {
    private static let railFilter = """
    WHERE ((t0.ZLASTWATCHEDDATE IS NOT NULL AND NSCoreDataStringSearch(t0.ZID, 'p-', 8, 0))
      AND (t0.ZCATEGORYID IS NULL OR NOT (t0.ZCATEGORYID IN ('hidden'))))
    """

    @Test func `series history reads use the watch-date index`() throws {
        try withStore { url, _ in
            let plan = try plan("SELECT * FROM ZSERIES t0 WHERE t0.ZLASTWATCHEDDATE IS NOT NULL ORDER BY t0.ZLASTWATCHEDDATE", at: url)
            #expect(plan.contains { $0.contains("SEARCH") && $0.contains("Z_Series_SwiftDataIndexOnBinarylastWatchedDate") }, "\(plan)")
            #expect(!plan.contains { $0.contains("SCAN") || $0.contains("TEMP B-TREE") }, "\(plan)")
        }
    }

    /// Ordering is for the plan only: every watched series is still read.
    @Test func `series history reads every watched series`() throws {
        try withStore { _, context in
            for index in 0 ..< 30 {
                let series = Series(id: "s\(index)", seriesId: index, name: "Series \(index)")
                series.lastWatchedDate = index.isMultiple(of: 3) ? Date(timeIntervalSinceReferenceDate: Double(index)) : nil
                context.insert(series)
            }
            try context.save()
            let read = try context.fetch(CloudHistoryQuery.series).map(\.id)
            #expect(Set(read) == Set((0 ..< 30).filter { $0.isMultiple(of: 3) }.map { "s\($0)" }))
            #expect(CloudHistoryQuery.series.fetchLimit == nil)
            // The order is what selects the index (see the plan test above).
            #expect(CloudHistoryQuery.series.sortBy.count == 1)
        }
    }

    @Test func `the mounted series watch row seeks its index`() throws {
        try withStore { url, _ in
            let sql = "SELECT * FROM ZSERIES t0 \(Self.railFilter) ORDER BY t0.ZLASTWATCHEDDATE DESC, t0.ZID DESC, t0.Z_PK LIMIT 21"
            let plan = try plan(sql, at: url)
            #expect(plan.contains { $0.contains("SEARCH") && $0.contains("Z_Series_SwiftDataIndexOnBinarylastWatchedDateid") }, "\(plan)")
            #expect(!plan.contains { $0.contains("SCAN") }, "\(plan)")
        }
    }

    @Test func `the series Show All page walks its index without sorting`() throws {
        try withStore { url, _ in
            let sql = "SELECT * FROM ZSERIES t0 \(Self.railFilter) ORDER BY t0.ZLASTWATCHEDDATE DESC, t0.ZID DESC LIMIT 60 OFFSET 60"
            let plan = try plan(sql, at: url)
            #expect(plan.contains { $0.contains("SEARCH") && $0.contains("Z_Series_SwiftDataIndexOnBinarylastWatchedDateid") }, "\(plan)")
            #expect(!plan.contains { $0.contains("SCAN") || $0.contains("TEMP B-TREE") }, "\(plan)")
        }
    }

    /// The SQL above is the descriptor's: two keys, lexical id, newest first.
    @Test func `series watch rows sort by watch date then lexical id`() {
        let descriptor = SeriesCollectionQuery.rowDescriptor(for: .continueWatching, playlistPrefix: "p-", excludedCategoryIDs: ["hidden"])
        #expect(descriptor.sortBy.count == 2)
        let page = SeriesCollectionQuery.pageDescriptor(
            for: .recentlyWatched, playlistPrefix: "p-", excludedCategoryIDs: ["hidden"], offset: 0, limit: 60
        )
        #expect(page.sortBy.count == 2)
    }

    @Test(arguments: ["ZMOVIE", "ZSERIES"])
    func `indexed-title counts read only the index`(table: String) throws {
        try withStore { url, _ in
            let sql = """
            SELECT COUNT(DISTINCT t0.Z_PK) FROM \(table) t0
            WHERE (t0.ZINDEXEDAT IS NOT NULL AND (t0.ZCATEGORYID IS NULL OR NOT (t0.ZCATEGORYID IN ('hidden'))))
            """
            let plan = try plan(sql, at: url)
            #expect(plan.contains { $0.contains("COVERING INDEX") && $0.contains("indexedAtcategoryId") }, "\(plan)")
        }
    }

    // MARK: - Store

    private func withStore(_ body: (URL, ModelContext) throws -> Void) throws {
        let schema = OnDiskCatalogStore.catalogSchema
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("LumeTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("catalog.store")
        let config = ModelConfiguration(schema: schema, url: url, cloudKitDatabase: .none)
        let container = try ModelContainer(for: schema, configurations: config)
        let context = ModelContext(container)
        context.insert(Movie(id: "m", streamId: 1, name: "Movie"))
        try context.save()
        try withExtendedLifetime(container) { try body(url, context) }
    }

    private func plan(_ sql: String, at url: URL) throws -> [String] {
        var handle: OpaquePointer?
        guard sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK, let database = handle else {
            if let handle { sqlite3_close(handle) }
            throw CocoaError(.fileReadUnknown)
        }
        defer { sqlite3_close(database) }
        // Resolved by EXPLAIN only, never executed.
        sqlite3_create_function_v2(database, "NSCoreDataStringSearch", 4, SQLITE_UTF8, nil, { _, _, _ in }, nil, nil, nil)
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "EXPLAIN QUERY PLAN " + sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw CocoaError(.fileReadUnknown)
        }
        defer { sqlite3_finalize(statement) }
        var steps: [String] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if let detail = sqlite3_column_text(statement, 3) { steps.append(String(cString: detail)) }
        }
        return steps
    }
}
