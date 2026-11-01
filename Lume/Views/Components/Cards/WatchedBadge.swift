//
//  WatchedBadge.swift
//  Lume
//
//  The tick that marks a finished movie or a fully watched series on its
//  poster, so watched state reads at a glance in rails and grids instead of
//  only through the card's menu. Episodes already show theirs on the episode
//  row. After upstream 82fc5e40.
//

import SwiftData
import SwiftUI

enum WatchedBadgeMetrics {
    #if os(tvOS)
        static let size: CGFloat = 30
        static let inset: CGFloat = 10
    #else
        static let size: CGFloat = 18
        static let inset: CGFloat = 6
    #endif
}

extension View {
    /// A tick in the artwork's top-trailing corner. White over a dark disc
    /// stays legible on bright artwork, and avoids `Color.accentColor`, which
    /// resolves to white on tvOS.
    func watchedBadge(_ isWatched: Bool) -> some View {
        overlay(alignment: .topTrailing) {
            if isWatched {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: WatchedBadgeMetrics.size))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, .black.opacity(0.55))
                    .padding(WatchedBadgeMetrics.inset)
                    .accessibilityLabel(Text("Watched"))
            }
        }
    }

    /// The tick for a series, once every episode this device has is watched.
    func seriesWatchedBadge(_ series: Series) -> some View {
        modifier(SeriesWatchedBadge(seriesID: series.id))
    }
}

/// Counts as the card appears rather than walking `series.episodes`, which
/// would fault in every episode of every show in a grid. `.task` runs again on
/// each appear, so the tick catches up after episodes are marked on the
/// series page. A show whose episodes aren't loaded yet shows no tick.
private struct SeriesWatchedBadge: ViewModifier {
    let seriesID: String
    @Environment(\.modelContext) private var modelContext
    @State private var isWatched = false

    func body(content: Content) -> some View {
        content
            .watchedBadge(isWatched)
            .task(id: seriesID) {
                isWatched = SeriesEpisodeProgress.allEpisodesWatched(seriesID: seriesID, in: modelContext)
            }
    }
}
