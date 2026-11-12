//
//  PagedCollection.swift
//  Lume
//
//  Shared incremental SwiftData loading for full collection grids. Category,
//  genre and library collections should hydrate only the window the viewer has
//  reached, rather than materialising an entire catalog-backed result.
//

import SwiftData
import SwiftUI

@MainActor
@Observable
final class PagedCollection<Item: PersistentModel> {
    private var window = PosterWindow<Item>()
    private(set) var pagination = PaginationMachine()

    var items: [Item] {
        window.items
    }

    var canLoadMore: Bool {
        pagination.canLoadMore
    }

    var isLoading: Bool {
        pagination.isLoading
    }

    /// Starts a new result set only when its query inputs changed. Returning to
    /// a grid from a detail screen keeps its loaded pages and scroll position.
    func prepare(for key: String) {
        guard pagination.prepare(for: key) else { return }
        window.removeAll()
    }

    /// Loads one page and preserves model identity/order. The descriptor owns
    /// the predicate and ordering; this type owns the common cursor and
    /// end-of-results contract.
    ///
    /// - Parameter duplicateKey: groups copies of one title (`PosterWindow`).
    func loadNextPage(
        in context: ModelContext,
        pageSize: Int,
        duplicateKey: @escaping (Item) -> AnyHashable? = { _ in nil },
        descriptor: (_ offset: Int, _ limit: Int) -> FetchDescriptor<Item>
    ) {
        guard let request = pagination.beginLoading() else { return }

        do {
            if window.isEmpty { window = PosterWindow(duplicateKey: duplicateKey) }
            var candidate = window
            var sourceOffset = request.offset
            var hasMore = true

            // A whole source page can consist of alternate streams for titles
            // already shown. Keep walking until the UI gains a new trailing
            // card (which can trigger its next onAppear) or the source ends.
            var added = 0
            repeat {
                let page = try context.fetch(descriptor(sourceOffset, pageSize))
                sourceOffset += page.count
                hasMore = page.count == pageSize
                added += candidate.accept(page)
            } while added == 0 && hasMore

            guard pagination.finish(
                request,
                scanned: sourceOffset - request.offset,
                hasMore: hasMore
            ) else {
                return
            }
            window = candidate
        } catch {
            // Preserve the already loaded window. A later appearance can retry
            // instead of turning a transient store failure into a false end.
            pagination.abandon(request)
        }
    }
}
