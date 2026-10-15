//
//  MainTabView+DeepLinks.swift
//  Lume
//
//  `lume://` deep links: a TMDB id opens a title's detail screen, a download
//  notification opens Downloads, a programme reminder opens Live TV, and the
//  Top Shelf's play / open links start playback or push a detail screen by
//  catalog id. Split out of MainTabView.swift to keep it within the file
//  length limit.
//

import SwiftData
import SwiftUI

extension MainTabView {
    /// Resolves a `lume://movie/{tmdbId}` / `lume://series/{tmdbId}` link to a
    /// catalog item, switches to the matching tab and pushes its detail screen.
    /// Silently ignores unknown links and titles not present in the catalog
    /// (e.g. a tmdbId that was never synced or enriched).
    func handleDeepLink(_ url: URL) -> DeepLinkDeliveryMachine.Outcome {
        guard let link = DeepLink(url: url) else { return .rejected }
        switch link {
        case let .movie(tmdbId):
            guard let movie = resolveMovie(tmdbId: tmdbId) else { return .rejected }
            openMovieDetail(movie)
        case let .series(tmdbId):
            guard let series = resolveSeries(tmdbId: tmdbId) else { return .rejected }
            openSeriesDetail(series)
        case .playMovie, .playEpisode, .playLive, .openSeries, .openMovie:
            return handleTopShelfLink(link)
        case .downloads:
            showsDownloads = true
        case .liveTV:
            router.selectedTab = .liveTV
            router.liveTVPath = NavigationPath()
        }
        return .handled
    }

    /// A Top Shelf link: `play` starts playback, `open` pushes a movie or series
    /// detail screen — both by catalog id, re-checked against the viewer's
    /// restrictions (`WidgetLinkResolver`).
    private func handleTopShelfLink(_ link: DeepLink) -> DeepLinkDeliveryMachine.Outcome {
        switch WidgetLinkResolver.resolve(link, in: modelContext, restriction: contentRestriction) {
        case let .play(media):
            // The in-app play paths: external player hand-off first, then a
            // player window (macOS) or a full-screen cover.
            if ExternalPlayback.open(media) { return .handled }
            #if os(macOS)
                MacPlayerWindowRouter.shared.play(media, using: openWindow)
            #else
                linkedMedia = media
            #endif
        case let .openSeries(series):
            openSeriesDetail(series)
        case let .openMovie(movie):
            openMovieDetail(movie)
        case nil:
            return .rejected
        }
        return .handled
    }

    private func openMovieDetail(_ movie: Movie) {
        router.selectedTab = .movies
        router.moviesPath = NavigationPath()
        router.moviesPath.append(movie)
    }

    private func openSeriesDetail(_ series: Series) {
        router.selectedTab = .series
        router.seriesPath = NavigationPath()
        router.seriesPath.append(series)
    }

    /// Finds a movie by `tmdbId`, preferring the active playlist but falling back
    /// to any other playlist's copy. Restricted categories stay hidden for a
    /// child profile.
    private func resolveMovie(tmdbId: Int) -> Movie? {
        let descriptor = FetchDescriptor<Movie>(predicate: #Predicate { $0.tmdbId == tmdbId })
        return CatalogMatchSelection.preferred(
            in: (try? modelContext.fetch(descriptor)) ?? [], restriction: contentRestriction,
            playlistPrefix: playlists.active(for: selectedPlaylistID)?.contentIDPrefix
        )
    }

    private func resolveSeries(tmdbId: Int) -> Series? {
        let descriptor = FetchDescriptor<Series>(predicate: #Predicate { $0.tmdbId == tmdbId })
        return CatalogMatchSelection.preferred(
            in: (try? modelContext.fetch(descriptor)) ?? [], restriction: contentRestriction,
            playlistPrefix: playlists.active(for: selectedPlaylistID)?.contentIDPrefix
        )
    }
}
