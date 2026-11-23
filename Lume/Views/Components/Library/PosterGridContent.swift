//
//  PosterGridContent.swift
//  Lume
//
//  The one poster grid: a category, a genre, a collection, a Home row's See
//  All, a filmography, search. It shows loading until the first page lands,
//  the empty state when nothing came, then the posters, a spinner while a
//  further page loads, and asks for that page as the last poster appears.
//  Loading is the caller's (`PagedCollection`, the category and genre loaders,
//  a search) — so is grouping copies of a title (`PosterWindow`).
//

import SwiftUI

/// What an empty grid says.
struct PosterGridEmptyState {
    var title: LocalizedStringKey
    var systemImage: String
    var description: Text?
}

struct PosterGridContent<Item: Identifiable, Cell: View>: View {
    let items: [Item]
    /// Nothing to show yet because the first page is still on its way.
    var isLoading = false
    /// A further page is loading under the posters already shown.
    var isLoadingMore = false
    /// Nil for a grid that is never empty when shown (inline search results).
    var empty: PosterGridEmptyState?
    /// Asked when the last poster appears; nil when everything is loaded.
    var onReachEnd: (() -> Void)?
    /// Set when the next page failed: the grid offers Try Again, calling it,
    /// where it would otherwise look empty or end early.
    var onRetry: (() -> Void)?
    @ViewBuilder let cell: (Item) -> Cell

    var body: some View {
        switch CollectionGridPresentation.resolve(hasItems: !items.isEmpty, isLoading: isLoading, hasFailed: onRetry != nil) {
        case .loading:
            ProgressView("Loading…")
                .frame(maxWidth: .infinity)
                .padding(.top, 40)
        case .empty:
            if let empty {
                ContentUnavailableView {
                    Label(empty.title, systemImage: empty.systemImage)
                } description: {
                    empty.description
                }
                .padding(.top, 40)
            }
        case .failed:
            ContentUnavailableView {
                Label("Couldn't Load", systemImage: "exclamationmark.triangle")
            } description: {
                Text("Check your connection and try again.")
            } actions: {
                retryButton
            }
            .padding(.top, 40)
        case .content:
            PosterGrid {
                ForEach(items) { item in
                    cell(item)
                        .onAppear {
                            if let onReachEnd, item.id == items.last?.id { onReachEnd() }
                        }
                }

                if isLoadingMore {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                } else if onRetry != nil {
                    retryButton
                        .frame(maxWidth: .infinity)
                }
            }
            .padding()
        }
    }

    private var retryButton: some View {
        Button("Try Again") { onRetry?() }
    }
}
