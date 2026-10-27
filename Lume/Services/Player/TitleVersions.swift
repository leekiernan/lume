//
//  TitleVersions.swift
//  Lume
//
//  The versions of one title in the catalog: the same movie listed in several
//  qualities or categories, or the same episode under each copy of its show.
//  The source selector already treats them as one title, and so do the
//  trackers, which only know a title by its TMDB id. Watched state follows:
//  marking or finishing one version marks them all, so a finished title
//  doesn't linger in Continue Watching through a version that wasn't played.
//
//  Tracker changes stay per title — the callers send one change for the
//  title, never one per version, or Trakt would count a play per version.
//

import Foundation
import SwiftData

enum TitleVersions {
    /// `movie` first, then every other movie with its TMDB id. Just `movie`
    /// when it has none: without the id there's no telling what else is it.
    static func movies(of movie: Movie, in context: ModelContext) -> [Movie] {
        guard let tmdbId = movie.tmdbId else { return [movie] }
        let id = movie.id
        let descriptor = FetchDescriptor<Movie>(predicate: #Predicate { $0.tmdbId == tmdbId && $0.id != id })
        return [movie] + ((try? context.fetch(descriptor)) ?? [])
    }

    /// `episode` first, then the same season and episode under every other
    /// show with its show's TMDB id. Only episodes already fetched: a show
    /// never opened has none yet, and picks the state up from the trackers.
    static func episodes(of episode: Episode, in context: ModelContext) -> [Episode] {
        guard let tmdbId = episode.series?.tmdbId else { return [episode] }
        let id = episode.id
        let season = episode.seasonNum
        let number = episode.episodeNum
        let descriptor = FetchDescriptor<Episode>(predicate: #Predicate {
            $0.seasonNum == season && $0.episodeNum == number && $0.id != id && $0.series?.tmdbId == tmdbId
        })
        return [episode] + ((try? context.fetch(descriptor)) ?? [])
    }
}
