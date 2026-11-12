//
//  MediaItemCell.swift
//  Lume
//
//  The card a rail of `HomeMediaItem`s shows, with its long-press menu and the
//  channel-logo card. Moved out of `HomeRows` once detail pages' similar-title
//  rails used it too.
//

import SwiftData
import SwiftUI

/// One movie, series or channel card as Home's rails show it — poster or
/// channel logo, watched badge and progress, the card focus treatment and the
/// long-press menu — shared by every rail of `HomeMediaItem`s (Home, the
/// Movies/Series pages, detail pages' similar titles).
struct MediaItemCell: View {
    let item: HomeMediaItem
    var seriesResume: [String: Double] = [:]
    var onPlayLive: (LiveStream) -> Void = { _ in }
    var onRemove: ((HomeMediaItem) -> Void)?
    var onVote: ((HomeMediaItem, RecommendationVote) -> Void)?
    var onStartMultiView: ((LiveStream) -> Void)?
    var animationNamespace: Namespace.ID?

    var body: some View {
        Group {
            switch item {
            case let .movie(movie):
                NavigationLink(value: movie) {
                    PosterCard(title: item.title, provider: item.imageURL?.absoluteString, posterPath: movie.posterPath,
                               request: .init(kind: .movie, id: movie.id, categoryID: movie.categoryId), progress: progress)
                        .watchedBadge(movie.isWatched)
                        .matchedTransitionSourceIfAvailable(id: movie.id, in: animationNamespace)
                }
                .posterCardButtonStyle()
            case let .series(series):
                NavigationLink(value: series) {
                    PosterCard(
                        title: item.title, provider: item.imageURL?.absoluteString, posterPath: series.posterPath,
                        request: .init(kind: .series, id: series.id, categoryID: series.categoryId), progress: progress
                    )
                    .seriesWatchedBadge(series)
                    .matchedTransitionSourceIfAvailable(id: series.id, in: animationNamespace)
                }
                .posterCardButtonStyle()
            case let .live(stream):
                Button {
                    onPlayLive(stream)
                } label: {
                    ChannelLogoCard(title: item.title, imageURL: item.imageURL)
                }
                .posterCardButtonStyle()
            }
        }
        .modifier(MediaItemMenu(
            item: item,
            onRemove: onRemove,
            onVote: onVote,
            onStartMultiView: onStartMultiView
        ))
    }

    private var progress: Double? {
        item.progress(seriesResume: seriesResume)
    }
}

/// The card's long-press menu. A channel gets the full channel menu — the same
/// one its row in Live TV carries, and the live favorite semantic (the flag
/// alone, no watchlist date) — while a movie or series gets the VOD one. Every
/// action a card offers is built here, in a single menu: only the outermost
/// `contextMenu` on a view survives, so a stacked second modifier would silently
/// replace the first.
struct MediaItemMenu: ViewModifier {
    let item: HomeMediaItem
    let onRemove: ((HomeMediaItem) -> Void)?
    let onVote: ((HomeMediaItem, RecommendationVote) -> Void)?
    let onStartMultiView: ((LiveStream) -> Void)?
    @Environment(\.modelContext) private var modelContext

    func body(content: Content) -> some View {
        let removeFromRecents = onRemove.map { action in { action(item) } }
        let voteAction = onVote.map { action in { (vote: RecommendationVote) in action(item, vote) } }

        switch item {
        case let .live(stream):
            content.liveChannelMenu(
                isFavorite: stream.isFavorite,
                onToggleFavorite: { LiveChannelFavorites.toggle(stream, in: modelContext) },
                onStartMultiView: onStartMultiView.map { action in { action(stream) } },
                onRemoveFromRecents: removeFromRecents
            )
        default:
            content.mediaFavoriteMenu(
                item,
                in: modelContext,
                onRemoveFromRecents: removeFromRecents,
                onVote: voteAction
            )
        }
    }
}

// MARK: - Channel card

/// The channel-logo card used by `MediaItemCell`. VOD posters and resume treatment
/// are provided separately by `PosterCard`.
///
/// Live channel logos are mostly transparent PNGs, so unlike movie/series
/// posters they can't fill the card themselves. They get a full card treatment
/// instead: a neutral dark gradient plate (consistent next to poster artwork in
/// any color scheme) and an inset so the logo never touches the edges.
private struct ChannelLogoCard: View {
    let title: String
    let imageURL: URL?

    var body: some View {
        CachedAsyncImage(url: imageURL, maxPixelSize: PosterCardMetrics.posterHeight, content: artworkContent)
            .frame(width: PosterCardMetrics.posterWidth, height: PosterCardMetrics.posterHeight)
            .background { liveCardBackground }
            .posterArtworkFrame(fillsWidth: false)
            .clipShape(RoundedRectangle(cornerRadius: PosterCardMetrics.cornerRadius, style: .continuous))
        // Skipped on tvOS for the same reason as `MovieCardView`: a shadow
        // after clipShape costs an offscreen pass per card and is invisible
        // at 10 feet.
        #if !os(tvOS)
            .shadow(radius: 2)
        #endif
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(title))
    }

    /// Like a poster, the logo stands alone once it loads; until then — or
    /// without one — the channel's name sits on the plate.
    @ViewBuilder
    private func artworkContent(_ phase: AsyncImagePhase) -> some View {
        switch phase {
        case let .success(image):
            image.resizable().aspectRatio(contentMode: .fit)
                .padding(PosterCardMetrics.liveLogoInset)
        case .empty, .failure:
            Text(title)
                .font(PosterCardMetrics.tileTitleFont)
                .foregroundStyle(.white)
                .lineLimit(4)
                .multilineTextAlignment(.leading)
                .padding(PosterCardMetrics.tileInset)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        @unknown default:
            EmptyView()
        }
    }

    /// The plate behind transparent channel logos. Fixed dark grays (not
    /// scheme-adaptive) so the card reads the same on the tvOS backdrop and in
    /// iOS/macOS light mode.
    private var liveCardBackground: some View {
        LinearGradient(
            colors: [Color(white: 0.30), Color(white: 0.14)],
            startPoint: .top,
            endPoint: .bottom
        )
    }
}
