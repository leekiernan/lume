//
//  SectionCollectionView.swift
//  Lume
//
//  Incremental full grid for remote-backed rows. The feed retains the complete
//  lightweight source order, while this view hydrates local catalog models only
//  as the viewer reaches each page.
//

import SwiftData
import SwiftUI

struct SectionCollectionSelection: Hashable {
    let section: HomeSectionRef
    let title: String
}

struct SectionCollectionView: View {
    let selection: SectionCollectionSelection
    let feed: SectionFeed
    var animationNamespace: Namespace.ID?

    @State private var loader = SectionCollectionLoadMachine()

    var body: some View {
        CategoryPage(title: selection.title) {
            CollectionGridContent(
                items: loader.items,
                isLoading: !loader.pagination.isPrepared || loader.pagination.isLoading,
                isLoadingMore: loader.pagination.isLoading,
                animationNamespace: animationNamespace,
                onReachEnd: { loader.requestNextPage(fetch: fetch) }
            )
        }
        .task(id: selection.section.token) {
            loader.open(key: selection.section.token, snapshot: feed.collection(for: selection.section), fetch: fetch)
        }
        .onDisappear { loader.cancel() }
    }

    private func fetch(_ request: SectionCollectionPageRequest) async throws -> SectionCollectionPage {
        try await feed.page(entries: request.entries, continuation: request.continuation, from: request.offset, limit: request.limit)
    }
}
