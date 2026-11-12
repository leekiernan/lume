//
//  HomeRows.swift
//  Lume
//
//  The horizontal rails on the Home screen (Recently Watched, Trending, etc.).
//  Their cards are `MediaItemCell`, shared with detail pages' similar-title
//  rails. Extracted from `HomeView` to keep that file focused on data loading
//  and screen composition.
//

import SwiftData
import SwiftUI

// MARK: - Row

struct HomeRow: View {
    /// A `Text` rather than a `LocalizedStringKey` so custom rows can pass their
    /// user-typed header verbatim while the built-in rows stay localized.
    let title: Text
    let items: [HomeMediaItem]
    /// Resume fractions keyed by series id, resolved once for the whole screen
    /// (`SeriesResumeLoader`) rather than per card — see `HomeMediaItem`.
    let seriesResume: [String: Double]
    let onPlayLive: (LiveStream) -> Void
    /// Destination for remote rows whose retained source contains more than the
    /// 20-card preview. Local rows supply their own collection navigation.
    var showAll: SectionCollectionSelection?
    var isRefreshing = false
    /// When set, each card gains a "Remove from Recently Watched" context menu.
    /// Only the Recently Watched row passes this; the others leave it nil.
    var onRemove: ((HomeMediaItem) -> Void)?
    /// When set, each card gains up/down vote actions. Only the "For You" row
    /// passes this; the others leave it nil.
    var onVote: ((HomeMediaItem, RecommendationVote) -> Void)?
    /// Seeds Multi-View from a channel card's long-press menu.
    var onStartMultiView: ((LiveStream) -> Void)?
    /// tvOS: pressing left on the row's first card. The Movies/Series pages use
    /// it to reveal the browse sidebar; Home leaves it nil.
    var onLeadingLeft: (() -> Void)?
    var animationNamespace: Namespace.ID?

    var body: some View {
        PosterRail(title: title, showAll: showAll, groupsFocus: true, isRefreshing: isRefreshing, onLeadingLeft: onLeadingLeft) {
            // One poster per title on every Home-style rail (For You, feeds,
            // custom rows), as in the grids (`PosterWindow`).
            RailItems(items: items.deduplicatedByTitle()) { index, item in
                MediaItemCell(
                    item: item,
                    seriesResume: seriesResume,
                    onPlayLive: onPlayLive,
                    onRemove: onRemove,
                    onVote: onVote,
                    onStartMultiView: onStartMultiView,
                    animationNamespace: animationNamespace
                )
                .onLeadingEdgeLeft(index == 0 ? onLeadingLeft : nil)
            }
        }
    }
}

// MARK: - For You row

/// The "For You" rail. Unlike the other rows it always renders when
/// recommendations are enabled: while the first list is still being computed it
/// shows a progress placeholder, and when there's nothing to suggest yet it
/// nudges the user toward the actions that seed recommendations.
struct ForYouRow: View {
    let items: [HomeMediaItem]
    let seriesResume: [String: Double]
    let isLoading: Bool
    let onPlayLive: (LiveStream) -> Void
    let onVote: (HomeMediaItem, RecommendationVote) -> Void
    var animationNamespace: Namespace.ID?

    var body: some View {
        if items.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                Text("For You")
                    .railHeadingStyle()
                    .padding(.horizontal)
                placeholder
                    .padding(.horizontal)
            }
        } else {
            HomeRow(
                title: Text("For You"),
                items: items,
                seriesResume: seriesResume,
                onPlayLive: onPlayLive,
                onVote: onVote,
                animationNamespace: animationNamespace
            )
        }
    }

    private var placeholder: some View {
        HStack(spacing: 12) {
            if isLoading {
                ProgressView()
                Text("Finding recommendations…")
            } else {
                Image(systemName: "sparkles")
                Text("Watch, favorite, or rate titles and we'll suggest more here.")
            }
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
    }
}
