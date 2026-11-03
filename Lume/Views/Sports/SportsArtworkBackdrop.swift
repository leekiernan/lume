//
//  SportsArtworkBackdrop.swift
//  Lume
//
//  A fixture's picture: the teams' colour wash at once, then the home side's
//  (or the competition's) fan art over it when `SportsArtwork` finds one.
//  Callers lay their own legibility gradient on top.
//

import SwiftUI

struct SportsArtworkBackdrop: View {
    let fixture: SportsFixture
    let size: SportsArtwork.Size
    var prefersPortrait = false
    @State private var artwork: Artwork?
    @State private var failedPosterURL: URL?
    @State private var enrichment = SportsArtworkEnrichment.shared
    @State private var failedEnrichedURLs: Set<URL> = []

    private struct Artwork {
        let url: URL
        let isPortrait: Bool
    }

    private struct Request: Hashable {
        let fixture: SportsFixture
        let size: SportsArtwork.Size
        let portrait: Bool
        let failedPosterURL: URL?
        let enrichedURL: URL?
    }

    var body: some View {
        GeometryReader { proxy in
            let portrait = prefersPortrait && size == .hero && proxy.size.width < 600
            let images = enrichment.images(for: fixture)
            let enrichedURL = images?.url(portrait: portrait, excluding: failedEnrichedURLs)
            let height = portrait && artwork?.isPortrait != true
                ? HeroArtworkPolicy.artworkHeight(width: proxy.size.width, heroHeight: proxy.size.height)
                : proxy.size.height
            ZStack {
                portrait ? Color.black : Color(white: 0.08)
                if !portrait {
                    TeamPalette.gradient(home: fixture.homePalette, away: fixture.awayPalette)
                }
            }
            // The picture is an overlay, so it fills whatever space the caller
            // gives and never sizes the backdrop: a `scaledToFill` image reports its
            // overflowing size to layout, and `.clipped()` alone only hides the
            // overflow — on iOS it widened the whole Sports page past the screen.
            .overlay(alignment: .top) {
                if let artwork {
                    HeroArtworkImage(url: artwork.url, sourceRatio: artwork.isPortrait ? 0.68 : HeroArtworkPolicy.landscapeRatio, onFailure: {
                        if artwork.url == enrichedURL {
                            failedEnrichedURLs.insert(artwork.url)
                            return
                        }
                        guard artwork.isPortrait, self.artwork?.url == artwork.url else { return }
                        failedPosterURL = artwork.url
                    })
                    .frame(width: proxy.size.width, height: height)
                    .mask {
                        if portrait {
                            LinearGradient(stops: [
                                .init(color: .black, location: 0),
                                .init(color: .black, location: artwork.isPortrait ? 0.4 : 0.7),
                                .init(color: .clear, location: 1)
                            ], startPoint: .top, endPoint: .bottom)
                        } else {
                            Color.black
                        }
                    }
                }
            }
            .clipped()
            .accessibilityHidden(true)
            .task(id: Request(fixture: fixture, size: size, portrait: portrait, failedPosterURL: failedPosterURL, enrichedURL: enrichedURL)) {
                artwork = nil
                if let enrichedURL {
                    artwork = Artwork(url: enrichedURL, isPortrait: portrait && enrichedURL == images?.poster)
                    return
                }
                if portrait, let url = await SportsArtwork.shared.portraitArt(for: fixture), url != failedPosterURL {
                    guard !Task.isCancelled else { return }
                    artwork = Artwork(url: url, isPortrait: true)
                } else {
                    guard !Task.isCancelled else { return }
                    let url = await SportsArtwork.shared.art(for: fixture, size: size)
                    guard !Task.isCancelled else { return }
                    artwork = url.map { Artwork(url: $0, isPortrait: false) }
                }
            }
        }
    }
}
