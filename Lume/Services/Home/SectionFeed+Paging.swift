//
//  SectionFeed+Paging.swift
//  Lume
//
//  Paging a section's retained source list against the local catalog — the
//  continuation a full collection grid uses without refetching its remote
//  list. Split from SectionFeed.swift to keep it within the size limit.
//

import Foundation

extension SectionFeed {
    /// Continues a grid's captured source, rather than a refreshed rail. A
    /// remote page is fetched only after its retained entries are exhausted.
    func page(entries initial: [HomeListEntry], continuation initialContinuation: HomeListContinuation?,
              from cursor: Int, limit: Int = 100) async throws -> SectionCollectionPage
    {
        guard let context else { return SectionCollectionPage(items: [], nextOffset: cursor, hasMoreCandidates: false) }
        let revision = loadGate.revision
        var entries = initial
        var continuation = initialContinuation
        var offset = cursor
        var items: [HomeMediaItem] = []
        repeat {
            try Task.checkCancellation()
            guard revision == loadGate.revision else { throw CancellationError() }
            let local = await SectionCollectionResolver.page(entries: entries, from: offset, limit: limit - items.count, context: context)
            items.append(contentsOf: local.items)
            offset = local.nextOffset
            if items.count >= limit || local.hasMoreCandidates { break }
            guard let next = continuation else { break }
            guard listAccountIsCurrent(next.key) else { throw CancellationError() }
            let remote = try await listCache.page(for: next.key, number: next.page, fetch: fetchListPage)
            guard revision == loadGate.revision, listAccountIsCurrent(next.key) else { throw CancellationError() }
            guard remote.nextPage.map({ $0 > next.page && $0 <= 50 }) ?? true else { throw HomeListError.invalidURL }
            entries = SectionCollectionResolver.normalizedEntries(entries + remote.entries, mediaType: surface.mediaType)
            continuation = remote.nextPage.map { HomeListContinuation(key: next.key, page: $0) }
        } while offset < entries.count || continuation != nil
        try Task.checkCancellation()
        guard revision == loadGate.revision else {
            throw CancellationError()
        }
        return SectionCollectionPage(items: items, nextOffset: offset, hasMoreCandidates: offset < entries.count || continuation != nil,
                                     sourceEntries: entries, continuation: continuation)
    }

    /// Resolves another local-catalog window from the retained source list.
    /// Nothing calls this from the 20-card rail; it is the common continuation
    /// path a full collection grid can use without refetching its remote list.
    func page(
        for section: HomeSectionRef,
        from cursor: Int,
        limit: Int = 100
    ) async -> SectionCollectionPage {
        guard let collection = collections[section], let context else {
            return SectionCollectionPage(items: [], nextOffset: cursor, hasMoreCandidates: false)
        }
        return await page(entries: collection.entries, from: cursor, limit: limit, context: context)
    }

    /// Resolves a page from a grid's captured source snapshot. A feed may
    /// revalidate while the grid is open; keeping that grid on one ordered
    /// source prevents its cursor from suddenly referring to a different list.
    func page(
        entries: [HomeListEntry],
        from cursor: Int,
        limit: Int = 100
    ) async -> SectionCollectionPage {
        guard let context else {
            return SectionCollectionPage(items: [], nextOffset: cursor, hasMoreCandidates: false)
        }
        return await page(entries: entries, from: cursor, limit: limit, context: context)
    }

    private func page(
        entries: [HomeListEntry],
        from cursor: Int,
        limit: Int,
        context: Context
    ) async -> SectionCollectionPage {
        await SectionCollectionResolver.page(
            entries: entries,
            from: cursor,
            limit: limit,
            context: context
        )
    }
}
