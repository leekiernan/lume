//
//  CatalogIndexBackfillTests.swift
//  LumeTests
//
//  `CatalogIndexBackfill` writes raw `CREATE INDEX` statements against the
//  catalog store, so its table and column names are hand-written strings that
//  no compiler checks. A typo there is silent — the index simply never appears
//  and the queries stay slow, which is exactly the failure this whole mechanism
//  exists to fix. These tests run it against a real on-disk store built from the
//  live models, so a renamed property or model breaks the build's tests rather
//  than a user's browse.
//

import Foundation
@testable import Lume
import SQLite3
import SwiftData
import Testing

@MainActor
struct CatalogIndexBackfillTests {
    /// The indexes the backfill is responsible for, as `(name, table)`. Kept as
    /// literals rather than read back from the type under test so a mistake in
    /// its table has to be made twice to pass.
    private static let expected: [(name: String, table: String)] = [
        ("Z_Movie_SwiftDataIndexOnBinaryadded", "ZMOVIE"),
        ("Z_Series_SwiftDataIndexOnBinarylastModified", "ZSERIES"),
        ("Z_LiveStream_SwiftDataIndexOnBinaryisFavoriteisHidden", "ZLIVESTREAM"),
        ("Z_LiveStream_SwiftDataIndexOnBinaryisHiddenlastWatchedDate", "ZLIVESTREAM"),
        ("Z_EPGListing_SwiftDataIndexOnBinarychannelIdend", "ZEPGLISTING"),
        ("Z_Movie_SwiftDataIndexOnBinaryisWatchedlastWatchedDate", "ZMOVIE"),
        ("Z_Episode_SwiftDataIndexOnBinaryisWatchedwatchProgress", "ZEPISODE"),
        ("Z_Movie_SwiftDataIndexOnBinaryaddedcategoryIdid", "ZMOVIE"),
        ("Z_Series_SwiftDataIndexOnBinarylastModifiedcategoryIdid", "ZSERIES")
    ]

    /// Builds a real SQLite-backed catalog store and returns its URL. The
    /// container is returned too and must outlive the test — see
    /// `SearchPredicateTests` for why.
    private func makeStore() throws -> (container: ModelContainer, url: URL) {
        let schema = Schema([
            Playlist.self, Lume.Category.self, LiveStream.self, Movie.self,
            Series.self, Episode.self, CastMember.self, EPGListing.self, EPGSource.self
        ])
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("catalog.store")
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let config = ModelConfiguration(schema: schema, url: url, cloudKitDatabase: .none)
        let container = try ModelContainer(for: schema, configurations: [config])
        // Force the store to actually exist on disk before anything reads it.
        let context = ModelContext(container)
        context.insert(Movie(id: "m1", streamId: 1, name: "A Movie"))
        try context.save()
        return (container, url)
    }

    private func indexNames(in url: URL) -> Set<String> {
        var handle: OpaquePointer?
        guard sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
              let database = handle
        else {
            if let handle { sqlite3_close(handle) }
            return []
        }
        defer { sqlite3_close(database) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "SELECT name FROM sqlite_master WHERE type = 'index'", -1, &statement, nil) == SQLITE_OK
        else { return [] }
        defer { sqlite3_finalize(statement) }
        var names: Set<String> = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if let raw = sqlite3_column_text(statement, 0) { names.insert(String(cString: raw)) }
        }
        return names
    }

    private func drop(_ names: some Sequence<String>, in url: URL) {
        var handle: OpaquePointer?
        guard sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK,
              let database = handle
        else {
            if let handle { sqlite3_close(handle) }
            return
        }
        defer { sqlite3_close(database) }
        for name in names {
            sqlite3_exec(database, "DROP INDEX IF EXISTS \(name)", nil, nil, nil)
        }
    }

    /// The case that matters: a store created before the `#Index` entries
    /// existed. SwiftData never revisits `#Index` on an existing file, so
    /// dropping the indexes reproduces exactly what every updating user has.
    @Test func `backfill creates the indexes an older store is missing`() throws {
        let (container, url) = try makeStore()
        _ = container

        drop(Self.expected.map(\.name), in: url)
        let before = indexNames(in: url)
        for expected in Self.expected {
            #expect(!before.contains(expected.name), "\(expected.name) should have been dropped")
        }

        CatalogIndexBackfill.run(storeURL: url)

        let after = indexNames(in: url)
        for expected in Self.expected {
            #expect(after.contains(expected.name), "\(expected.name) was not created — check its table and column names")
        }
    }

    /// A fresh install already has these from the model declarations, so the
    /// backfill must be a no-op rather than creating a second, differently
    /// named copy of each.
    @Test func `backfill is a no-op on a store that already has them`() throws {
        let (container, url) = try makeStore()
        _ = container

        let before = indexNames(in: url)
        CatalogIndexBackfill.run(storeURL: url)
        #expect(indexNames(in: url) == before)
    }

    @Test func `fresh stores omit the redundant watched index`() throws {
        let (container, url) = try makeStore()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        withExtendedLifetime(container) {
            let names = indexNames(in: url)
            #expect(!names.contains("Z_Movie_SwiftDataIndexOnBinaryisWatched"))
            #expect(names.contains("Z_Movie_SwiftDataIndexOnBinaryisWatchedlastWatchedDate"))
        }
    }

    @Test func `backfill retires the index that makes mounted watch rails scan the catalogue`() throws {
        let (container, url) = try makeStore()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try withExtendedLifetime(container) {
            try withDatabase(at: url) { database in
                // Reproduce a store from before the model declaration changed.
                let sql = "CREATE INDEX Z_Movie_SwiftDataIndexOnBinaryisWatched ON ZMOVIE (ZISWATCHED COLLATE BINARY ASC)"
                #expect(sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK)
            }
            CatalogIndexBackfill.run(storeURL: url)
            #expect(!indexNames(in: url).contains("Z_Movie_SwiftDataIndexOnBinaryisWatched"))
            let plan = try mountedWatchPlan(at: url)
            #expect(plan.contains { $0.contains("Z_Movie_SwiftDataIndexOnBinaryisWatchedlastWatchedDate") })
            #expect(!plan.contains { $0.contains("USE TEMP B-TREE FOR ORDER BY") }, "\(plan)")
            #expect(try ModelContext(container).fetchCount(FetchDescriptor<Movie>()) == 1)
        }
    }

    @Test func `backfill retains the old index when its replacement cannot be created`() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("old.store")
        try withDatabase(at: url, create: true) { database in
            // A store too old to have the replacement's column must retain
            // its existing index, even though other backfills are skipped.
            let sql = """
            CREATE TABLE ZMOVIE (ZISWATCHED INTEGER);
            CREATE INDEX Z_Movie_SwiftDataIndexOnBinaryisWatched ON ZMOVIE (ZISWATCHED);
            """
            #expect(sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK)
        }
        CatalogIndexBackfill.run(storeURL: url)
        #expect(indexNames(in: url).contains("Z_Movie_SwiftDataIndexOnBinaryisWatched"))
    }

    /// The SQL captured from a mounted @Query includes a Z_PK tie-breaker
    /// that ModelContext.fetch does not add. Keep it in this regression probe.
    private func mountedWatchPlan(at url: URL) throws -> [String] {
        try withDatabase(at: url) { database in
            // These functions are only resolved by EXPLAIN, never executed.
            sqlite3_create_function_v2(database, "NSCoreDataStringSearch", 4, SQLITE_UTF8, nil, { _, _, _ in }, nil, nil, nil)
            sqlite3_create_collation(database, "NSCollateFinderlike", SQLITE_UTF8, nil) { _, _, _, _, _ in 0 }
            let sql = """
            EXPLAIN QUERY PLAN SELECT t0.ZID, t0.ZNAME, t0.ZCATEGORYID FROM ZMOVIE t0
            WHERE t0.ZLASTWATCHEDDATE IS NOT NULL AND t0.ZISWATCHED = 0
              AND NSCoreDataStringSearch(t0.ZID, 'probe-', 8, 0)
              AND (t0.ZCATEGORYID IS NULL OR NOT(t0.ZCATEGORYID IN ('hidden')))
            ORDER BY t0.ZLASTWATCHEDDATE DESC, t0.ZNAME COLLATE NSCollateFinderlike,
                     t0.ZID COLLATE NSCollateFinderlike, t0.Z_PK LIMIT 21
            """
            var statement: OpaquePointer?
            #expect(sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK)
            guard let statement else { return [] }
            defer { sqlite3_finalize(statement) }
            var plan: [String] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                if let detail = sqlite3_column_text(statement, 3) { plan.append(String(cString: detail)) }
            }
            return plan
        }
    }

    private func withDatabase<T>(at url: URL, create: Bool = false, _ body: (OpaquePointer) throws -> T) throws -> T {
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | (create ? SQLITE_OPEN_CREATE : 0)
        let result = sqlite3_open_v2(url.path, &handle, flags, nil)
        guard result == SQLITE_OK, let database = handle else {
            if let handle { sqlite3_close(handle) }
            throw CocoaError(.fileReadUnknown)
        }
        defer { sqlite3_close(database) }
        return try body(database)
    }

    /// A missing file is the pre-first-launch state; it must not create one.
    @Test func `backfill leaves a missing store alone`() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("absent.store")
        CatalogIndexBackfill.run(storeURL: url)
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }
}
