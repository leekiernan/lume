import Foundation
import OSLog
import SwiftData

/// Only the common paging envelope, not a universal provider DTO. Each adapter
/// retains its authentication, decoding and model/relationship mapping.
nonisolated struct ProviderImportPage<Item> {
    let items: [Item]
    let total: Int
}

nonisolated enum ProviderImportError: Error, Equatable {
    case incompletePage(fetched: Int, expected: Int)
    case invalidTotal(Int)
    /// A library without a fixed length failed part-way; what it read is kept.
    case openEndedStopped(fetched: Int)
    /// One library failed (a slow page past the timeout, a server error) while
    /// the others imported.
    case libraryUnavailable(String)
}

/// Tells a library without a fixed length from one with a real total, by how
/// it pages. Some Jellyfin-compatible servers front ranked lists (popular,
/// trending, a streaming service's catalogue) as libraries whose every page
/// reports a total of what was read plus one more page: every page after the
/// first moves the total by exactly its own item count. A real library growing
/// during a scan doesn't move in step with the pages.
nonisolated struct ProviderTotalTracker {
    private var previousTotal: Int?
    private var pages = 0
    private(set) var isOpenEnded = false

    /// An empty page says nothing about how the total moves (it is how such a
    /// library ends), so it leaves the verdict as it was.
    mutating func record(total: Int, itemCount: Int) {
        guard itemCount > 0 else { return }
        pages += 1
        if let previousTotal {
            let inStep = total - previousTotal == itemCount
            isOpenEnded = pages == 2 ? inStep : isOpenEnded && inStep
        }
        previousTotal = total
    }
}

nonisolated struct ProviderCategory {
    let id: String
    let name: String
    /// nil preserves an existing parent; providers without hierarchy use this.
    var parentID: Int?
}

extension ContentSyncManager {
    /// A completed walk is the authority to prune. An empty library is valid;
    /// an empty page before the advertised end is not. Already saved pages may
    /// remain after failure, but the caller must not sweep or mark coverage.
    ///
    /// With `openEndedLimit`, a library without a fixed length
    /// (`ProviderTotalTracker`) is read only that far, and that counts as
    /// complete: rows beyond it are pruned, as a rolling ranked list should be.
    /// A page failure inside such a library ends it as `.openEndedStopped`,
    /// keeping what it read, instead of failing the sync. A library with a real
    /// total keeps the strict behaviour.
    func walkProviderPages<Item>(
        openEndedLimit: Int? = nil,
        fetch: (Int) async throws -> ProviderImportPage<Item>,
        consume: ([Item]) throws -> Void,
        report: (Int, Int) async -> Void
    ) async throws -> Int {
        var fetched = 0
        var tracker = ProviderTotalTracker()
        while true {
            try Task.checkCancellation()
            let page: ProviderImportPage<Item>
            do {
                page = try await fetch(fetched)
            } catch where openEndedLimit != nil && tracker.isOpenEnded && !Task.isCancelled && !(error is CancellationError) {
                Logger.database.error("Open-ended library stopped at \(fetched, privacy: .public) item(s): \(error.localizedDescription, privacy: .public); keeping what it read")
                throw ProviderImportError.openEndedStopped(fetched: fetched)
            }
            try Task.checkCancellation()
            guard page.total >= 0 else { throw ProviderImportError.invalidTotal(page.total) }
            tracker.record(total: page.total, itemCount: page.items.count)
            let openEnded = openEndedLimit != nil && tracker.isOpenEnded
            guard !page.items.isEmpty || fetched >= page.total || openEnded else {
                throw ProviderImportError.incompletePage(fetched: fetched, expected: page.total)
            }
            if !page.items.isEmpty { try consume(page.items) }
            fetched += page.items.count
            let shownTotal = openEnded ? min(page.total, openEndedLimit ?? page.total) : page.total
            await report(fetched, shownTotal)
            try Task.checkCancellation()
            if fetched >= page.total || (openEnded && page.items.isEmpty) { return fetched }
            if openEnded, let openEndedLimit, fetched >= openEndedLimit {
                Logger.database.info("Library has no fixed length; read its first \(fetched, privacy: .public) item(s)")
                return fetched
            }
        }
    }

    /// Walks one library. A walk the server cut short — fewer items than it
    /// advertised, or a nonsense total — keeps that library's rows and returns
    /// the error instead of throwing, so the other libraries still import.
    /// The caller skips pruning that kind and reports the error once every
    /// library has had its turn, which keeps `lastSyncDate` and coverage from
    /// advancing. Any other failure (network, auth, cancellation) throws.
    func walkLibrary(_ name: String, _ walk: () async throws -> Void) async throws -> ProviderImportError? {
        do {
            try await walk()
            return nil
        } catch let error as ProviderImportError {
            Logger.database.error("Library \(name, privacy: .public) walk incomplete (\(String(describing: error), privacy: .public)); its rows are kept and its kind isn't pruned")
            return error
        }
    }

    /// Continue after structural truncation, retaining the first error as the
    /// phase's prune veto. Transport/auth/storage/cancellation failures stop.
    func walkLibraries<Library>(
        _ libraries: [Library], name: KeyPath<Library, String>, walk: (Library) async throws -> Void
    ) async throws -> ProviderImportError? {
        var incomplete: ProviderImportError?
        for library in libraries {
            try Task.checkCancellation()
            let failure = try await walkLibrary(library[keyPath: name]) { try await walk(library) }
            incomplete = incomplete ?? failure
        }
        try Task.checkCancellation()
        return incomplete
    }

    /// What a concurrent walk of several libraries brought back.
    struct LibraryWalk<Seen: Sendable> {
        /// Each library that finished, in no particular order.
        var seen: [Seen] = []
        /// The first library that didn't finish; vetoes the kind's prune.
        var incomplete: ProviderImportError?
    }

    /// Walks `libraries` up to `width` at a time: a server with many
    /// on-demand libraries took minutes one at a time, and their requests are
    /// independent. The walks overlap on the network; their upserts still run
    /// one at a time on this actor.
    ///
    /// A library that fails is skipped rather than failing the sync, and its
    /// kind isn't pruned. `isFatal` errors (authentication) and cancellation
    /// still end the sync, as does every library failing, with the first
    /// failure.
    func walkLibrariesConcurrently<Library: Sendable, Seen: Sendable>(
        _ libraries: [Library],
        name: @escaping @Sendable (Library) -> String,
        width: Int = 4,
        isFatal: @escaping @Sendable (Error) -> Bool,
        finished: @escaping @Sendable (_ done: Int, _ total: Int) async -> Void = { _, _ in },
        walk: @escaping @Sendable (isolated ContentSyncManager, Library) async throws -> Seen
    ) async throws -> LibraryWalk<Seen> {
        var result = LibraryWalk<Seen>()
        var failures: [Error] = []
        try await withThrowingTaskGroup(of: (Int, Result<Seen, Error>).self) { group in
            var next = 0
            func start() {
                guard next < libraries.count else { return }
                let index = next, library = libraries[index]
                next += 1
                group.addTask {
                    do {
                        return try await (index, .success(walk(self, library)))
                    } catch {
                        return (index, .failure(error))
                    }
                }
            }
            for _ in 0 ..< min(width, libraries.count) {
                start()
            }
            var done = 0
            while let (index, outcome) = try await group.next() {
                done += 1
                switch outcome {
                case let .success(seen):
                    result.seen.append(seen)
                case let .failure(error):
                    if Task.isCancelled || error is CancellationError || isFatal(error) {
                        group.cancelAll()
                        throw error
                    }
                    let library = name(libraries[index])
                    let incomplete = error as? ProviderImportError ?? .libraryUnavailable(error.localizedDescription)
                    if !(error is ProviderImportError) { failures.append(error) }
                    Logger.database.error("Library \(library, privacy: .public) skipped (\(error.localizedDescription, privacy: .public)); its rows are kept and its kind isn't pruned")
                    result.incomplete = result.incomplete ?? incomplete
                }
                await finished(done, libraries.count)
                start()
            }
        }
        try Task.checkCancellation()
        if !libraries.isEmpty, failures.count == libraries.count, let first = failures.first { throw first }
        return result
    }

    /// Provider order/metadata are refreshed in place. User visibility, order,
    /// icons and on-demand freshness belong to the stored row, never the DTO.
    /// The lookup includes new inserts, so repeated IDs cannot replace them.
    ///
    /// `keepsEmptyIDs`: Xtream has always stored a category whose provider id is
    /// empty (as `<uuid>-<type>-`), and its titles may point at it; skipping it
    /// would prune that row and drop them from browse. Every other provider
    /// treats an empty id as unusable.
    func syncProviderCategories(
        _ rows: [ProviderCategory], type: CategoryType, playlistId: UUID, keepsEmptyIDs: Bool = false
    ) throws {
        let context = ModelContext(modelContainer)
        context.autosaveEnabled = false
        var lookup = try fetchCategoryLookup(context: context, playlistId: playlistId, type: type)
        guard let playlist = try context.fetch(
            FetchDescriptor<Playlist>(predicate: #Predicate { $0.id == playlistId })
        ).first else { return }

        var seen = Set<String>()
        for (index, row) in rows.enumerated() where keepsEmptyIDs || !row.id.isEmpty {
            seen.insert(row.id)
            if let category = lookup[row.id] {
                if category.name != row.name { category.name = row.name }
                if let parentID = row.parentID, category.parentId != parentID { category.parentId = parentID }
                if category.sortOrder != index { category.sortOrder = index }
            } else {
                let category = Category(apiId: row.id, name: row.name, parentId: row.parentID ?? 0, type: type, playlist: playlist)
                category.sortOrder = index
                context.insert(category)
                lookup[row.id] = category
            }
        }
        if context.hasChanges { try context.save() }
        // Invalid/empty IDs do not constitute a successfully imported catalog.
        pruneCategories(playlistId: playlistId, type: type, seenApiIds: seen, importedCount: seen.count)
    }
}
