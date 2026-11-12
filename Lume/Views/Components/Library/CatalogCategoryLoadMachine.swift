import Foundation
import Observation

struct CatalogCategoryKey: Hashable {
    let categoryID: String
    let visibility: String
    let profile: UUID?
}

/// One category lifecycle for both media kinds. Import work is injected so the
/// machine owns publication, never provider persistence or pruning.
@Observable
final class CatalogCategoryLoadMachine<Item: Hashable> {
    typealias Fetch = (String, Int, Int) throws -> [Item]
    typealias Import = (Category, Playlist) async throws -> Void

    private(set) var key: CatalogCategoryKey?
    private var window: PosterWindow<Item>
    var items: [Item] {
        window.items
    }

    private(set) var pagination = PaginationMachine()
    /// Which scope may publish the import running for it. A new scope takes
    /// this over; the walk itself is `runningImport`.
    private var importToken: RequestToken?
    /// The category whose provider import is running, whoever owns its
    /// publication. One walk per category: a visibility or profile change
    /// mid-import waits for it instead of walking the portal a second time.
    @ObservationIgnored private var runningImport: String?
    @ObservationIgnored private var generation = RequestToken()
    @ObservationIgnored private var loadedInitialPage = false
    /// Opens of the same category waiting for the import already running —
    /// see `claimOpen`. Resumed when that walk ends.
    @ObservationIgnored private var importWaiters: [CheckedContinuation<Void, Never>] = []
    let pageSize: Int

    /// - Parameter duplicateKey: groups copies of one title (`PosterWindow`).
    init(pageSize: Int = 100, duplicateKey: @escaping (Item) -> AnyHashable? = { _ in nil }) {
        self.pageSize = pageSize
        window = PosterWindow(duplicateKey: duplicateKey)
    }

    var isImporting: Bool {
        importToken != nil || (runningImport != nil && runningImport == key?.categoryID)
    }

    func invalidate() {
        generation = RequestToken()
        releaseImport()
        key = nil
        window.removeAll()
        loadedInitialPage = false
        pagination = PaginationMachine()
    }

    func open(category: Category, key nextKey: CatalogCategoryKey, fetch: @escaping Fetch, importContent: @escaping Import) async {
        guard await claimOpen(nextKey) else { return }
        let owner = generation
        if let playlist = stalkerPlaylist(category), category.contentImportedAt == nil {
            guard await runImport(category, playlist: playlist, owner: owner, action: importContent) else { return }
        }
        guard isCurrent(owner) else { return }
        // A reopen that waited on this import may already have loaded it.
        if !loadedInitialPage { loadNextPage(fetch: fetch) }
        if let playlist = stalkerPlaylist(category), category.contentImportedAt != nil, category.stalkerContentStale {
            guard await runImport(category, playlist: playlist, owner: owner, action: importContent) else { return }
            reloadWindow(fetch: fetch)
        }
    }

    /// Whether this open has work to do. A new key starts afresh; the same
    /// key with its first page loaded keeps it. Either way, if this category's
    /// import is still running — the same key after leaving it, which
    /// cancelled the open that started it, or a new visibility or profile —
    /// this open waits for that walk, then decides again: the caller loads the
    /// page if it completed, or imports afresh if it didn't.
    private func claimOpen(_ nextKey: CatalogCategoryKey) async -> Bool {
        if key != nextKey {
            key = nextKey
            generation = RequestToken()
            releaseImport()
            window.removeAll()
            loadedInitialPage = false
            if !pagination.prepare(for: nextKey.categoryID) { pagination.restart() }
        } else if loadedInitialPage {
            return false
        }
        guard runningImport == nextKey.categoryID else { return true }
        await withCheckedContinuation { importWaiters.append($0) }
        return key == nextKey && !loadedInitialPage && runningImport == nil && !Task.isCancelled
    }

    func loadNextPage(fetch: Fetch) {
        // Cached rows remain pageable during revalidation; suppressing their
        // trailing onAppear can otherwise strand the grid at its first page.
        guard let key, !isImporting || loadedInitialPage, let request = pagination.beginLoading() else { return }
        do {
            // A page of other copies of titles already shown adds no poster,
            // so no trailing poster would ask for the next: fetch on.
            var candidate = window
            var offset = request.offset
            var hasMore = true
            var added = 0
            repeat {
                let rows = try fetch(key.categoryID, offset, pageSize)
                offset += rows.count
                hasMore = rows.count == pageSize
                added += candidate.accept(rows)
            } while added == 0 && hasMore
            guard pagination.finish(request, scanned: offset - request.offset, hasMore: hasMore) else {
                return
            }
            window = candidate
            loadedInitialPage = true
        } catch {
            pagination.abandon(request)
        }
    }

    func refresh(category: Category, fetch: @escaping Fetch, importContent: @escaping Import) async {
        guard key?.categoryID == category.id, !isImporting, let playlist = stalkerPlaylist(category) else { return }
        let owner = generation
        guard await runImport(category, playlist: playlist, owner: owner, action: importContent) else { return }
        guard let rows = try? fetch(category.id, 0, pageSize) else { return }
        pagination.replaceWindow(scanned: rows.count, hasMore: rows.count == pageSize)
        window.replace(with: rows)
        loadedInitialPage = true
    }

    private func reloadWindow(fetch: Fetch) {
        guard let key else { return }
        // Rows, not posters: other copies were scanned past to reach them.
        let limit = max(pagination.nextOffset, pageSize)
        // A failed revalidation fetch must not replace a usable cached window.
        guard let rows = try? fetch(key.categoryID, 0, limit) else { return }
        pagination.replaceWindow(scanned: rows.count, hasMore: rows.count == limit)
        window.replace(with: rows)
    }

    private func runImport(_ category: Category, playlist: Playlist, owner: RequestToken, action: Import) async -> Bool {
        guard isCurrent(owner), runningImport == nil else { return false }
        let token = RequestToken()
        importToken = token
        runningImport = category.id
        defer {
            if importToken == token { releaseImport() }
            finishRunningImport()
        }
        do { try await action(category, playlist) } catch { /* Existing best-effort import contract. */ }
        return isCurrent(owner)
    }

    private func releaseImport() {
        importToken = nil
    }

    private func finishRunningImport() {
        runningImport = nil
        let waiters = importWaiters
        importWaiters = []
        for waiter in waiters {
            waiter.resume()
        }
    }

    private func isCurrent(_ owner: RequestToken) -> Bool {
        generation == owner && !Task.isCancelled
    }

    private func stalkerPlaylist(_ category: Category) -> Playlist? {
        guard let playlist = category.playlist, playlist.sourceType == .stalker else { return nil }
        return playlist
    }
}
