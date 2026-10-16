import Foundation
import Observation

struct SectionCollectionPageRequest {
    let entries: [HomeListEntry]
    let continuation: HomeListContinuation?
    let offset: Int
    let limit: Int
}

/// Owns the grid's captured source and page task. A disappearing grid releases
/// the unfinished cursor immediately; a late response cannot publish into a
/// resumed page or clear its newer task.
@Observable
final class SectionCollectionLoadMachine {
    typealias Fetch = (SectionCollectionPageRequest) async throws -> SectionCollectionPage

    private(set) var items: [HomeMediaItem] = []
    private(set) var pagination = PaginationMachine()
    private var entries: [HomeListEntry] = []
    private var continuation: HomeListContinuation?
    @ObservationIgnored private var owner = RequestToken()
    @ObservationIgnored private var nextTask: Task<Void, Never>?
    let pageSize: Int

    init(pageSize: Int = 100) {
        self.pageSize = pageSize
    }

    func open(key: String, snapshot: SectionCollectionSnapshot?, fetch: @escaping Fetch) {
        if pagination.key != key {
            cancel()
            pagination.prepare(for: key)
            entries = snapshot?.entries ?? []
            continuation = snapshot?.continuation
            items = snapshot?.preview ?? []
            pagination.seed(nextOffset: snapshot?.nextOffset ?? 0, canLoadMore: snapshot?.hasMoreCandidates ?? false)
        }
        if items.isEmpty { requestNextPage(fetch: fetch) }
    }

    @discardableResult
    func requestNextPage(fetch: @escaping Fetch) -> Task<Void, Never>? {
        guard nextTask == nil, pagination.canLoadMore, !pagination.isLoading else { return nil }
        let token = owner
        nextTask = Task {
            await loadNextPage(owner: token, fetch: fetch)
            if owner == token { nextTask = nil }
        }
        return nextTask
    }

    func cancel() {
        owner = RequestToken()
        nextTask?.cancel()
        nextTask = nil
        pagination.cancelLoading()
    }

    private func loadNextPage(owner token: RequestToken, fetch: Fetch) async {
        while !Task.isCancelled, owner == token, let request = pagination.beginLoading() {
            do {
                let page = try await fetch(.init(entries: entries, continuation: continuation, offset: request.offset, limit: pageSize))
                guard owner == token else { return }
                try Task.checkCancellation()
                let hasMore = page.hasMoreCandidates && page.nextOffset > request.offset
                guard pagination.finish(request, scanned: page.nextOffset - request.offset, hasMore: hasMore) else { return }
                entries = page.sourceEntries ?? entries
                continuation = page.continuation
                var existing = Set(items.map(\.id))
                items.append(contentsOf: page.items.filter { existing.insert($0.id).inserted })
                if !page.items.isEmpty || !hasMore { return }
            } catch {
                if owner == token { pagination.abandon(request) }
                return
            }
        }
    }
}
