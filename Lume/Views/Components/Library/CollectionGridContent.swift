//
//  CollectionGridContent.swift
//  Lume
//
//  The poster grid of a full-page collection — a Home row's See All, a
//  person's filmography: `PosterGridContent` over Home's mixed media items.
//  Owners keep the paging.
//

import SwiftUI

struct CollectionGridContent: View {
    let items: [HomeMediaItem]
    /// Nothing to show yet because the first page is still on its way.
    let isLoading: Bool
    /// A further page is loading under the posters already shown.
    let isLoadingMore: Bool
    var emptyTitle: LocalizedStringKey = "Nothing Here Yet"
    var emptyMessage: Text?
    var animationNamespace: Namespace.ID?
    let onReachEnd: () -> Void

    var body: some View {
        PosterGridContent(
            items: items, isLoading: isLoading, isLoadingMore: isLoadingMore,
            empty: .init(title: emptyTitle, systemImage: "rectangle.stack", description: emptyMessage),
            onReachEnd: onReachEnd,
            cell: itemLink
        )
    }

    @ViewBuilder
    private func itemLink(_ item: HomeMediaItem) -> some View {
        switch item {
        case let .movie(movie):
            CatalogPosterLink(item: movie, animationNamespace: animationNamespace) { movie in
                MovieCardView(movie: movie, fillsWidth: true)
            }
        case let .series(series):
            CatalogPosterLink(item: series, animationNamespace: animationNamespace) { series in
                SeriesCardView(series: series, fillsWidth: true)
            }
        case .live:
            EmptyView()
        }
    }
}
