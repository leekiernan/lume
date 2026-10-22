//
//  CatalogIndexBackfill.swift
//  Lume
//
//  Creates the catalog store's newer `#Index` entries on a store that already
//  exists, because SwiftData will not.
//
//  Measured on a real 373 MB store (2026-09-08, and again after this PR's model
//  changes): adding an entry to `#Index<Movie>` and relaunching leaves
//  `sqlite_master` byte-identical and every `EXPLAIN QUERY PLAN` unchanged.
//  Declaring a `VersionedSchema` pair and opening at the newer version does not
//  help either — the store kept `NSStoreModelVersionIdentifiers = ["1.0.0"]`
//  and no `CREATE INDEX` was issued. The reason is in Core Data's own contract:
//  an entity's version hash covers attributes and relationships and
//  deliberately excludes fetch indexes, so a store whose entities are unchanged
//  is judged compatible, opened as-is, and no migration stage is ever
//  considered. The `#Index` declarations only reach a store at the moment the
//  file is created — i.e. fresh installs.
//
//  So the indexes are created here, directly, once, before the container opens.
//  An index is a pure SQLite object: it changes no row, no column and no
//  version hash, and Core Data neither validates nor notices `sqlite_master`.
//  Each statement is named exactly what SwiftData names its own, so
//  `IF NOT EXISTS` is a no-op on a fresh install that already has them, and a
//  future SwiftData migration finds its index already in place.
//
//  A failure here is not an error worth surfacing: the queries still return the
//  same rows, just more slowly, which is precisely where this app was before.
//

import Foundation
import OSLog
import SQLite3

nonisolated enum CatalogIndexBackfill {
    /// One index this app needs the store to have.
    ///
    /// `name` mirrors SwiftData's own convention — `Z_<Model>_SwiftDataIndexOn`
    /// plus `Binary` (the collation it always uses) plus the property names
    /// concatenated — so it collides with, rather than duplicates, the index a
    /// freshly-created store already carries. See any `Z_LiveStream_…` entry in
    /// an existing store for the shape.
    private struct Index {
        let name: String
        let table: String
        let columns: [String]
        /// Retired only after this replacement exists.
        var replaces: String?

        var createStatement: String {
            let cols = columns.map { "\($0) COLLATE BINARY ASC" }.joined(separator: ", ")
            return "CREATE INDEX IF NOT EXISTS \(name) ON \(table) (\(cols))"
        }
    }

    /// The indexes added after the store format was first shipped. Each one is
    /// declared on its `@Model` as well — that is what gives fresh installs the
    /// index — and repeated here because an existing store never sees that
    /// declaration.
    ///
    /// Keep the two in step: a new `#Index` entry that is not listed here
    /// silently helps only new users.
    private static let indexes: [Index] = [
        // "Recently Added" on the Movies and Series tabs sorts on these string
        // columns. Unindexed, the rail cost `SCAN ZMOVIE` plus a temp B-tree
        // sort of all 179,104 rows — 222 ms per run, re-run on every catalog
        // write. Only usable because the sort descriptors pass
        // `comparator: .lexical`; the default localized comparator emits
        // `COLLATE NSCollateFinderlike`, which no binary index can serve.
        Index(name: "Z_Movie_SwiftDataIndexOnBinaryadded", table: "ZMOVIE", columns: ["ZADDED"]),
        Index(name: "Z_Series_SwiftDataIndexOnBinarylastModified", table: "ZSERIES", columns: ["ZLASTMODIFIED"]),
        // Cloud/profile watchlist reads now order by their existing date
        // indexes. Ensure older stores have them too: otherwise even that
        // ordered descriptor still has to scan the catalogue and sort.
        Index(name: "Z_Movie_SwiftDataIndexOnBinaryaddedToWatchlistDate", table: "ZMOVIE", columns: ["ZADDEDTOWATCHLISTDATE"]),
        Index(name: "Z_Series_SwiftDataIndexOnBinaryaddedToWatchlistDate", table: "ZSERIES", columns: ["ZADDEDTOWATCHLISTDATE"]),
        // The same for the series history read, ordered by watch date.
        Index(name: "Z_Series_SwiftDataIndexOnBinarylastWatchedDate", table: "ZSERIES", columns: ["ZLASTWATCHEDDATE"]),
        // The Live TV rail's two section gates and its virtual collections.
        // With only the single-column indexes present SQLite chose the
        // `isHidden` one — which matches ~54,000 of 56,895 channels — and never
        // used `isFavorite` or `lastWatchedDate`: 7.6 ms and 8.0 ms per run,
        // 18-25 runs on a cold launch of a tab that may never be opened.
        // Measured with the composites: 0.6 ms and 0.02 ms.
        Index(
            name: "Z_LiveStream_SwiftDataIndexOnBinaryisFavoriteisHidden",
            table: "ZLIVESTREAM",
            columns: ["ZISFAVORITE", "ZISHIDDEN"]
        ),
        // Equality column first — see the note on `#Index<LiveStream>`: the
        // intuitive `[lastWatchedDate, isHidden]` order is not chosen without
        // table statistics, and Core Data never runs ANALYZE.
        Index(
            name: "Z_LiveStream_SwiftDataIndexOnBinaryisHiddenlastWatchedDate",
            table: "ZLIVESTREAM",
            columns: ["ZISHIDDEN", "ZLASTWATCHEDDATE"]
        ),
        // A grouped channel's other qualities, looked up as a channel is
        // tuned and when the player builds its Source menu. The column is new
        // with grouping: on the first launch after the update the store has
        // not migrated yet and this fails quietly, then lands on the next.
        Index(
            name: "Z_LiveStream_SwiftDataIndexOnBinaryvariantKey",
            table: "ZLIVESTREAM",
            columns: ["ZVARIANTKEY"]
        ),
        // The in-player EPG lookups bound on `end > now`; the store only had
        // `[channelId, start]`. `TVPlayerContent.guideListings` has cited a
        // "channelId + end index" in a comment since it was written, without
        // one ever existing.
        // Continue Watching / Recently Watched (Home and the Movies tab) and
        // the episode resume lookup. With only single-column indexes SQLite
        // chose `isWatched = 0`, which nearly every row matches: the whole
        // movie table read and sorted for ten rows — 4.4 s main-thread hangs on
        // tvOS whenever Home's queries re-ran — and every unwatched episode
        // read for the handful in progress.
        Index(
            name: "Z_Movie_SwiftDataIndexOnBinaryisWatchedlastWatchedDate",
            table: "ZMOVIE",
            columns: ["ZISWATCHED", "ZLASTWATCHEDDATE"],
            replaces: "Z_Movie_SwiftDataIndexOnBinaryisWatched"
        ),
        Index(
            name: "Z_Episode_SwiftDataIndexOnBinaryisWatchedwatchProgress",
            table: "ZEPISODE",
            columns: ["ZISWATCHED", "ZWATCHPROGRESS"]
        ),
        // Recently Added walks `added` / `lastModified` newest first until 21
        // rows pass the playlist prefix and hidden-category checks. With only
        // the sort column indexed each step read the title's whole row; with
        // most categories hidden that was every row, the main-thread `pread`
        // behind the Movies tab's hangs on a profile switch. With the two
        // filter columns in the index the checks never leave it.
        Index(
            name: "Z_Movie_SwiftDataIndexOnBinaryaddedcategoryIdid",
            table: "ZMOVIE",
            columns: ["ZADDED", "ZCATEGORYID", "ZID"]
        ),
        Index(
            name: "Z_Series_SwiftDataIndexOnBinarylastModifiedcategoryIdid",
            table: "ZSERIES",
            columns: ["ZLASTMODIFIED", "ZCATEGORYID", "ZID"]
        ),
        // The Series tab's watch rows and their Show All grid, ordered by
        // watch date then lexical id. Ending ORDER BY in a third term — a
        // mounted @Query appends `Z_PK` — scanned and sorted the whole table
        // on every read with only `[lastWatchedDate]`.
        Index(
            name: "Z_Series_SwiftDataIndexOnBinarylastWatchedDateid",
            table: "ZSERIES",
            columns: ["ZLASTWATCHEDDATE", "ZID"]
        ),
        // The indexer's indexed-title counts filter hidden categories too;
        // with `categoryId` beside `indexedAt` the count never reads a row.
        Index(
            name: "Z_Movie_SwiftDataIndexOnBinaryindexedAtcategoryId",
            table: "ZMOVIE",
            columns: ["ZINDEXEDAT", "ZCATEGORYID"]
        ),
        Index(
            name: "Z_Series_SwiftDataIndexOnBinaryindexedAtcategoryId",
            table: "ZSERIES",
            columns: ["ZINDEXEDAT", "ZCATEGORYID"]
        ),
        Index(
            name: "Z_EPGListing_SwiftDataIndexOnBinarychannelIdend",
            table: "ZEPGLISTING",
            columns: ["ZCHANNELID", "ZEND"]
        ),
        // Source-scoped publication deletes only the previous snapshot for one
        // EPG source. Without this index a large guide would scan every row
        // before each atomic replacement.
        Index(
            name: "Z_EPGListing_SwiftDataIndexOnBinarysourceID",
            table: "ZEPGLISTING",
            columns: ["ZSOURCEID"]
        )
    ]

    /// Creates any missing index on the store at `url`, if that store exists.
    ///
    /// Must run *before* the `ModelContainer` opens the file: this takes its own
    /// connection, and `CREATE INDEX` takes a write lock for as long as it needs
    /// to build the b-tree (a second or two for the largest table on a very big
    /// catalog, once, on the launch after updating — never again).
    ///
    /// Does nothing when the file is absent, which is every fresh install: there
    /// the `#Index` declarations on the models create these at store-creation
    /// time and this finds nothing to do on the next launch either.
    static func run(storeURL: URL) {
        guard FileManager.default.fileExists(atPath: storeURL.path) else { return }

        var handle: OpaquePointer?
        // No SQLITE_OPEN_CREATE: if the path is wrong we want to do nothing, not
        // leave an empty database next to the real one.
        guard sqlite3_open_v2(storeURL.path, &handle, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK,
              let database = handle
        else {
            if let handle { sqlite3_close(handle) }
            Logger.database.debug("Catalog index backfill: could not open the store; leaving it alone")
            return
        }
        defer { sqlite3_close(database) }

        for index in indexes where tableExists(index.table, in: database) {
            if sqlite3_exec(database, index.createStatement, nil, nil, nil) != SQLITE_OK {
                let message = String(cString: sqlite3_errmsg(database))
                Logger.database.debug("Catalog index backfill: \(index.name, privacy: .public) skipped — \(message, privacy: .public)")
                continue
            }
            // @Query adds Z_PK to the rail's ORDER BY. With both indexes
            // present SQLite then prefers the single-column watched index,
            // reading the whole catalogue instead of just dated movies.
            // The composite covers all uses of its leading column. Only drop
            // the old index once its replacement was created successfully.
            if let replaced = index.replaces {
                sqlite3_exec(database, "DROP INDEX IF EXISTS \(replaced)", nil, nil, nil)
            }
        }
    }

    /// Guards against running `CREATE INDEX` on a store from before a model
    /// existed — a missing table is a skip, not an error.
    private static func tableExists(_ table: String, in database: OpaquePointer) -> Bool {
        var statement: OpaquePointer?
        let sql = "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ?"
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, table, -1, unsafeBitCast(-1 as Int, to: sqlite3_destructor_type.self))
        return sqlite3_step(statement) == SQLITE_ROW
    }
}
