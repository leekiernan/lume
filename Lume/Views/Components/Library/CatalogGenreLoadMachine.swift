import Foundation
import Observation
import SwiftData

struct CatalogGenreKey: Hashable {
    let genre: String
    let playlistPrefix: String
    let visibility: String
    let profile: UUID?
}

/// Owns genre scan publication, not database contexts. Only identifiers cross
/// the background boundary; hydration remains in the caller's main context.
@Observable
final class CatalogGenreLoadMachine<Item: Hashable> {
    typealias Fetch = (GenrePageRequest) async -> GenrePage
    typealias Hydrate = (PersistentIdentifier) -> Item?

    private(set) var key: CatalogGenreKey?
    private var window: PosterWindow<Item>
    var items: [Item] {
        window.items
    }

    private(set) var pagination = PaginationMachine()
    @ObservationIgnored private var owner = RequestToken()
    @ObservationIgnored private var nextTask: Task<Void, Never>?
    let pageSize: Int

    /// - Parameter duplicateKey: groups copies of one title (`PosterWindow`).
    init(pageSize: Int = 100, duplicateKey: @escaping (Item) -> AnyHashable? = { _ in nil }) {
        self.pageSize = pageSize
        window = PosterWindow(duplicateKey: duplicateKey)
    }

    func open(key nextKey: CatalogGenreKey, excluded: Set<String>, fetch: @escaping Fetch, hydrate: @escaping Hydrate) async {
        if key != nextKey {
            cancel()
            key = nextKey
            window.removeAll()
            if !pagination.prepare(for: nextKey.genre) { pagination.restart() }
        }
        guard items.isEmpty else { return }
        await loadNextPage(excluded: excluded, fetch: fetch, hydrate: hydrate)
    }

    @discardableResult
    func requestNextPage(excluded: Set<String>, fetch: @escaping Fetch, hydrate: @escaping Hydrate) -> Task<Void, Never>? {
        guard nextTask == nil, pagination.canLoadMore, !pagination.isLoading else { return nil }
        let token = owner
        nextTask = Task {
            await loadNextPage(excluded: excluded, fetch: fetch, hydrate: hydrate)
            if owner == token { nextTask = nil }
        }
        return nextTask
    }

    func cancel() {
        owner = RequestToken()
        nextTask?.cancel()
        nextTask = nil
        // Preserve the visible snapshot and retry the unfinished offset.
        pagination.replaceWindow(scanned: pagination.nextOffset, hasMore: pagination.canLoadMore)
    }

    private func loadNextPage(excluded: Set<String>, fetch: Fetch, hydrate: Hydrate) async {
        guard let key else { return }
        let token = owner
        while !Task.isCancelled, token == owner, let request = pagination.beginLoading() {
            let page = await fetch(.init(genre: key.genre, playlistPrefix: key.playlistPrefix,
                                         excludedCategoryIDs: excluded, offset: request.offset, pageSize: pageSize))
            guard token == owner else { return }
            guard !Task.isCancelled else {
                pagination.abandon(request)
                return
            }
            // A zero-progress source cannot keep an empty scan loop alive.
            let hasMore = !page.reachedEnd && page.scanned > 0
            guard pagination.finish(request, scanned: page.scanned, hasMore: hasMore) else { return }
            // Other copies of titles already shown add no poster; scan on.
            let added = window.accept(page.ids.compactMap(hydrate))
            if added > 0 || !hasMore { return }
        }
    }
}
