//
//  CollectionGridContent.swift
//  Lume
//
//  The poster grid of a full-page collection — a Home row's See All, a
//  person's filmography — with its loading and empty states. Owners keep the
//  paging; this asks for the next page when the last poster appears.
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
        switch CollectionGridPresentation.resolve(hasItems: !items.isEmpty, isLoading: isLoading) {
        case .empty:
            ContentUnavailableView {
                Label(emptyTitle, systemImage: "rectangle.stack")
            } description: {
                emptyMessage
            }
            .padding(.top, 40)
        case .loading:
            ProgressView("Loading…").frame(maxWidth: .infinity).padding(.top, 40)
        case .content:
            PosterGrid {
                ForEach(items) { item in
                    itemLink(item)
                        .onAppear {
                            if item.id == items.last?.id { onReachEnd() }
                        }
                }

                if isLoadingMore {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                }
            }
            .padding()
        }
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
