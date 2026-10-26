import SwiftUI

/// One heart state; connected tracker marks describe where the action syncs.
/// Only the heart fills. Shared by detail actions and every player overlay.
struct MediaFavoriteGlyph: View {
    let isFavorite: Bool
    var showTrackers = true
    var trackerSize: CGFloat = 16

    private var connectedTrackers: [WatchlistProvider] {
        showTrackers ? WatchlistProvider.allCases.filter(\.service.isConnected) : []
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: isFavorite ? "heart.fill" : "heart")
                .symbolReplaceTransition(value: isFavorite)
            ForEach(connectedTrackers, id: \.self) { tracker($0.mark) }
        }
        .accessibilityElement(children: .ignore)
        .task(id: MediaFavorites.watchlistAccounts) {
            guard showTrackers else { return }
            await MediaFavorites.refreshWatchlists()
        }
    }

    private func tracker(_ mark: Image) -> some View {
        mark
            .renderingMode(.template)
            .resizable()
            .scaledToFit()
            .frame(width: trackerSize, height: trackerSize)
    }
}
