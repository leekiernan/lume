//
//  TitleSourcePlayback.swift
//  Lume
//
//  What to play for a copy picked from a detail page's Source button. The page
//  plays it as it stands — it isn't rebuilt for the copy first — so this is
//  the page's own Play choice made for another copy: a film itself, or a
//  series' next episode (`SeriesEpisodeProgress`), fetching the copy's episodes
//  first when it has none, as Continue Watching does.
//

import Foundation
import SwiftData

enum TitleSourcePlayback {
    static func media(for source: TitleSource, restriction: ContentRestriction, in context: ModelContext) async -> PlayableMedia? {
        guard !restriction.hides(categoryID: source.copy.categoryID) else { return nil }
        guard let playlists = try? context.fetch(FetchDescriptor<Playlist>()) else { return nil }
        switch source.copy {
        case let .movie(movie):
            guard let playlist = PlaylistOwner.playlist(forContentID: movie.id, in: playlists, fallback: .firstAvailable)
            else { return nil }
            return PlayableMedia.from(movie: movie, playlist: playlist)
        case let .series(series):
            guard let playlist = PlaylistOwner.playlist(forContentID: series.id, in: playlists, fallback: .firstAvailable)
            else { return nil }
            await fetchEpisodesIfNone(series, playlist: playlist, in: context)
            guard let episode = SeriesEpisodeProgress.nextEpisode(in: series.episodes, fallback: nil) else { return nil }
            return PlayableMedia.from(episode: episode, playlist: playlist)
        }
    }

    private static func fetchEpisodesIfNone(_ series: Series, playlist: Playlist, in context: ModelContext) async {
        guard series.episodes.isEmpty, playlist.supportsPerSeriesEpisodeFetch,
              let parsed = try? await ContentSyncManager(modelContainer: context.container).fetchEpisodes(
                  seriesId: series.seriesId, seriesElementId: series.id, playlist: playlist
              ),
              // An empty answer may be a provider hiccup: stamping the episode
              // cache with it would suppress the detail page's own fetch.
              !parsed.episodes.isEmpty, !Task.isCancelled
        else { return }
        series.applyFetchedEpisodes(parsed, into: context)
    }
}
